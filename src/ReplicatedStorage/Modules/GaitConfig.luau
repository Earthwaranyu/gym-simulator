--!strict
--[[
	GaitConfig — walking and running, as joint angles.

	The last animation in the game that was not ours. Training poses, attacks and flight
	are all generated from joint angles because the project rule is that nothing here may
	be somebody else's work; locomotion was still Roblox's stock Animate script playing
	Roblox's uploaded walk and run clips.

	It is also the animation players see most. Training is a pose at a machine, flying is
	occasional, fighting is bursts — running is every other second of the session, and it
	was the same jog every other experience on the platform has. A game about becoming
	physically enormous should not move like the default avatar.

	Unlike FlightConfig, almost nothing new was needed. PoseConfig.JointMotion already
	carries a Phase field whose own comment says it is "what makes alternating curls and
	a running stride read correctly", and PosePlayback.AlphaAt with a Continuous motion
	style is already a phase-offset cosine cycle driver. Flight needed its own type
	because it *holds* a shape blended by speed; a gait *cycles*, which is exactly what a
	Pose already is. The only genuinely new thing is the driver — stride rate from ground
	speed instead of from a machine's rep interval.

	These live here rather than in PoseConfig.List for a concrete reason: that module's
	self-test asserts there are exactly 35 poses and that every one has Cycles == 1 as an
	exercise. FlightConfig set the precedent for a pose table outside it.

	Phase structure is lifted from StairClimber (PoseConfig.luau), which is a walk cycle
	in all but name: hips half a cycle apart, knees lagging the hips by a fifth, arms
	opposite the same-side leg.

	Axis conventions and the ~150 degree ceiling are PoseConfig's, unchanged — +X swings
	a limb forward, a knee bends negative, an elbow bends positive, +Z lifts the right
	arm out. Past about 150 a BallSocketConstraint animates the long way round.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local GaitConfig = {}

export type Gait = {
	Id: string,
	-- Shaped exactly as a PoseConfig.Pose so PosePlayback drives it unchanged.
	Pose: PoseConfig.Pose,
}

--[[
	Every joint a gait drives.

	Declared once so a cycle cannot silently forget one. Roblox's own run clip keeps
	playing underneath — nothing disables the default Animate script, and disabling it
	would take jump, fall, climb and swim with it — so any joint not named here keeps
	the stock animation and reads as a mismatch against the rest of the body.

	Ankles are included, which FlightConfig deliberately omits. A flier's feet trail
	behind them and nobody looks; a runner's feet are the part touching the ground, and
	an ankle left on the stock clip is the joint that gives the whole cycle away.
]]
GaitConfig.Joints = {
	"Root",
	"Waist",
	"Neck",
	"RightShoulder",
	"LeftShoulder",
	"RightElbow",
	"LeftElbow",
	"RightHip",
	"LeftHip",
	"RightKnee",
	"LeftKnee",
	"RightAnkle",
	"LeftAnkle",
}

-- Fade in and out against whatever the animator is doing. Faster in than out: starting
-- to move should feel immediate, while stopping eases back into Roblox's idle rather
-- than snapping to it.
GaitConfig.BLEND_IN_SECONDS = 0.16
GaitConfig.BLEND_OUT_SECONDS = 0.24

-- How quickly the walk-to-sprint blend chases a change of speed. Slower than the speed
-- itself so the body settles into a run rather than flickering between silhouettes when
-- a player taps a key.
GaitConfig.BLEND_RESPONSIVENESS = 8

--[[
	Where in the cycle each foot plants.

	The reason this can be stated at all is that the cycle is ours. With a stock clip the
	best available option is a timer that drifts against the animation; here the footfall
	is a known point in the phase, so dust lands on the frame the foot actually hits.

	Left at 0 and right at 0.5 because the left hip carries Phase 0.5 — at raw phase 0 it
	is the left leg that is forward.
]]
GaitConfig.FOOTFALL_PHASES = { { Phase = 0, Side = "Left" }, { Phase = 0.5, Side = "Right" } }

local function deg(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

--[[
	Walk — light, bouncy and upright.

	An anime walk is not a real one. The arms swing further than a person's actually do,
	the knees lift higher, the toes point, and the whole body rises and falls more than
	physics would justify — GaitController supplies that bob, and it is deliberately the
	largest of the three gaits.

	The waist counter-rotates against the hips and the neck counter-rotates against the
	waist on Y, which is what keeps the head facing forward while the shoulders roll.
	Neck X is left at zero in all three poses on purpose: the head's *pitch* is the
	controller's job, cancelling the lean so the character always looks where they are
	going. Hand-writing it here is what previously had the sprint staring at the floor.
]]
local WALK: PoseConfig.Pose = {
	Id = "GaitWalk",
	Cycles = 1,
	MotionStyle = "Snapped",
	Joints = {
		-- Rolls side to side. The vertical bob is not here: a body rises and falls once
		-- per *step* and a cycle is two steps, and one pose cannot run a single joint at
		-- double frequency. GaitController applies it.
		{ Joint = "Root", Rest = deg(0, 0, -3), Peak = deg(0, 0, 3) },
		{ Joint = "Waist", Rest = deg(0, -9, 0), Peak = deg(0, 9, 0) },
		{ Joint = "Neck", Rest = deg(0, 6, 0), Peak = deg(0, -6, 0) },

		-- Arms oppose the same-side leg, so the right arm carries the left leg's phase.
		-- Z is how far the arm is held out from the body — PoseConfig's lat pulldown uses
		-- 145 for arms straight out sideways, and StairClimber uses 10. A bigger *swing*
		-- than a real walk, still held close to the ribs.
		{ Joint = "RightShoulder", Rest = deg(-30, 0, 8), Peak = deg(34, 0, 9), Phase = 0.5 },
		{ Joint = "LeftShoulder", Rest = deg(-30, 0, -8), Peak = deg(34, 0, -9) },
		{ Joint = "RightElbow", Rest = deg(20, 0, 0), Peak = deg(42, 0, 0), Phase = 0.5 },
		{ Joint = "LeftElbow", Rest = deg(20, 0, 0), Peak = deg(42, 0, 0) },

		{ Joint = "RightHip", Rest = deg(-26, 0, 5), Peak = deg(40, 0, 5) },
		{ Joint = "LeftHip", Rest = deg(-26, 0, -5), Peak = deg(40, 0, -5), Phase = 0.5 },
		-- Knees lag the hips by a fifth of a cycle: the thigh swings, then the shin
		-- follows. Leading or matching the hip is what makes a leg look like a plank.
		{ Joint = "RightKnee", Rest = deg(-6, 0, 0), Peak = deg(-68, 0, 0), Phase = 0.2 },
		{ Joint = "LeftKnee", Rest = deg(-6, 0, 0), Peak = deg(-68, 0, 0), Phase = 0.7 },
		-- Pointed toes. Small, but it is most of what separates a drawn walk from a
		-- simulated one.
		{ Joint = "RightAnkle", Rest = deg(-12, 0, 0), Peak = deg(16, 0, 0), Phase = 0.15 },
		{ Joint = "LeftAnkle", Rest = deg(-12, 0, 0), Peak = deg(16, 0, 0), Phase = 0.65 },
	},
}

--[[
	Sprint — the shonen run.

	Long strides, knees high, and arms driving hard and tight from a locked elbow. The
	forward lean is the controller's, growing quadratically with speed, so this pose is
	authored as if upright and the lean is added on top.
]]
local SPRINT: PoseConfig.Pose = {
	Id = "GaitSprint",
	Cycles = 1,
	MotionStyle = "Snapped",
	Joints = {
		{ Joint = "Root", Rest = deg(0, 0, -4), Peak = deg(0, 0, 4) },
		{ Joint = "Waist", Rest = deg(0, -14, 0), Peak = deg(0, 14, 0) },
		{ Joint = "Neck", Rest = deg(0, 7, 0), Peak = deg(0, -7, 0) },

		-- Tucked tighter than the walk. Tucking the elbows in is most of what separates
		-- a sprint from a jog; an earlier build had these held wider than the walk and
		-- it read as windmilling.
		{ Joint = "RightShoulder", Rest = deg(-58, 0, 4), Peak = deg(56, 0, 5), Phase = 0.5 },
		{ Joint = "LeftShoulder", Rest = deg(-58, 0, -4), Peak = deg(56, 0, -5) },
		-- Held near ninety through the whole cycle. A sprinter's elbow angle barely
		-- changes; it is the shoulder that drives, and a flapping forearm reads as a jog.
		{ Joint = "RightElbow", Rest = deg(88, 0, 0), Peak = deg(104, 0, 0), Phase = 0.5 },
		{ Joint = "LeftElbow", Rest = deg(88, 0, 0), Peak = deg(104, 0, 0) },

		{ Joint = "RightHip", Rest = deg(-48, 0, 4), Peak = deg(66, 0, 4) },
		{ Joint = "LeftHip", Rest = deg(-48, 0, -4), Peak = deg(66, 0, -4), Phase = 0.5 },
		{ Joint = "RightKnee", Rest = deg(-14, 0, 0), Peak = deg(-118, 0, 0), Phase = 0.2 },
		{ Joint = "LeftKnee", Rest = deg(-14, 0, 0), Peak = deg(-118, 0, 0), Phase = 0.7 },
		{ Joint = "RightAnkle", Rest = deg(-18, 0, 0), Peak = deg(26, 0, 0), Phase = 0.15 },
		{ Joint = "LeftAnkle", Rest = deg(-18, 0, 0), Peak = deg(26, 0, 0), Phase = 0.65 },
	},
}

--[[
	Dash — the ninja run, for flat out only.

	The whole silhouette is the arms: straight, locked, and trailing behind the body,
	which is why they barely cycle at all. Everything else follows from committing to
	that — the strides go long and low rather than high, the waist stops rotating because
	the shoulders are pinned back, and the controller's lean reaches its deepest here.

	The shoulders stay negative at both ends of the cycle, unlike the other two gaits
	which swing through zero. That is the difference between arms that trail and arms
	that pump, and GaitConfig's self-test asserts it so a retune cannot quietly turn this
	back into a sprint.
]]
local DASH: PoseConfig.Pose = {
	Id = "GaitDash",
	Cycles = 1,
	MotionStyle = "Snapped",
	Joints = {
		{ Joint = "Root", Rest = deg(0, 0, -2), Peak = deg(0, 0, 2) },
		-- Barely rotates. A body committed this far forward with its arms pinned back
		-- has nothing left to counter-rotate with, and a waist swinging under trailing
		-- arms reads as a stumble.
		{ Joint = "Waist", Rest = deg(0, -5, 0), Peak = deg(0, 5, 0) },
		{ Joint = "Neck", Rest = deg(0, 3, 0), Peak = deg(0, -3, 0) },

		-- Swept back and held there. The small swing is the arms reacting to the stride
		-- rather than driving it.
		{ Joint = "RightShoulder", Rest = deg(-76, 0, 12), Peak = deg(-62, 0, 14), Phase = 0.5 },
		{ Joint = "LeftShoulder", Rest = deg(-76, 0, -12), Peak = deg(-62, 0, -14) },
		-- Nearly locked straight, which is the read: the arms are a pair of lines behind
		-- the body, not a pair of angles.
		{ Joint = "RightElbow", Rest = deg(4, 0, 0), Peak = deg(10, 0, 0), Phase = 0.5 },
		{ Joint = "LeftElbow", Rest = deg(4, 0, 0), Peak = deg(10, 0, 0) },

		-- Longer than the sprint's and lower: the legs reach rather than climb.
		{ Joint = "RightHip", Rest = deg(-56, 0, 3), Peak = deg(72, 0, 3) },
		{ Joint = "LeftHip", Rest = deg(-56, 0, -3), Peak = deg(72, 0, -3), Phase = 0.5 },
		{ Joint = "RightKnee", Rest = deg(-8, 0, 0), Peak = deg(-92, 0, 0), Phase = 0.2 },
		{ Joint = "LeftKnee", Rest = deg(-8, 0, 0), Peak = deg(-92, 0, 0), Phase = 0.7 },
		{ Joint = "RightAnkle", Rest = deg(-24, 0, 0), Peak = deg(30, 0, 0), Phase = 0.15 },
		{ Joint = "LeftAnkle", Rest = deg(-24, 0, 0), Peak = deg(30, 0, 0), Phase = 0.65 },
	},
}

local gaits: { Gait } = {
	{ Id = "Walk", Pose = WALK },
	{ Id = "Sprint", Pose = SPRINT },
	{ Id = "Dash", Pose = DASH },
}

GaitConfig.List = gaits
GaitConfig.Walk = WALK
GaitConfig.Sprint = SPRINT
GaitConfig.Dash = DASH

--[[
	Where the walk finishes becoming the sprint, as a fraction of the gait blend — and
	therefore where the sprint starts becoming the dash.

	Low, because the blend is measured against the *global* speed ceiling of 64 rather
	than against each character's own top speed. A fresh player's sprint is 24 studs a
	second, which is only (24-16)/(64-16) = 0.167 of that range, so the walk has to be
	fully behind them by then or holding Shift would still look like walking.

	Everything above it is the long climb to the ninja run, which is the point: the dash
	is something forty Legs earns rather than something every player gets for free the
	moment they hold a key.

	Lives here rather than in Formulas, unlike flight's equivalent: nothing about this
	crosses the wire, so it is a pose-blending detail rather than a shared protocol
	constant.
]]
GaitConfig.SPRINT_FRACTION = 0.15

--[[
	The furthest along the walk-sprint-dash blend a pose is ever allowed to travel.

	Derived, not chosen: it is exactly the blend a player with no Legs at all gets
	when they hold shift. So the gait a new character has is the gait every
	character has, at any power -- which is the look this game wants.

	This deliberately retires the design the comment above `speedRange` describes,
	where the ninja run was something Legs earned. The dash pose is still authored
	and still in this file; it is one constant away from being reachable again.

	Note what this does *not* touch: nothing here changes how fast anybody moves.
	A maxed sprinter still covers 64 studs a second. Only the pose stops escalating,
	and the stride keeps tracking the ground underneath it.
]]
GaitConfig.MAX_POSE_BLEND =
	Formulas.GaitBlend(Formulas.SprintSpeed(0), Formulas.WalkSpeed(0), Formulas.SPRINT_CEILING)

local byId: { [string]: Gait } = {}
for _, gait in gaits do
	if byId[gait.Id] ~= nil then
		error(`[GaitConfig] Duplicate gait id "{gait.Id}"`)
	end
	byId[gait.Id] = gait
end

function GaitConfig.Get(gaitId: string): Gait?
	return byId[gaitId]
end

--[[
	The walk and sprint versions of one joint, blended into a single JointMotion.

	Returned as a JointMotion so the result flows through the same PosePlayback.PoseAt
	and AlphaAt everything else uses — one implementation of "angles become a CFrame",
	not three. Phase is taken from the walk entry: the two cycles share a phase
	structure by design, and interpolating between two phases would slide the whole
	stride sideways as a player accelerated.
]]
local function motionIn(pose: PoseConfig.Pose, jointName: string): PoseConfig.JointMotion?
	for _, motion in pose.Joints do
		if motion.Joint == jointName then
			return motion
		end
	end
	return nil
end

--[[
	The two silhouettes a blend sits between, and how far between them it is.

	Walk to Sprint occupies the lower part of the range and Sprint to Dash the upper,
	split at SPRINT_FRACTION — the same shape as FlightPoseController's hover/glide/cruise
	pairing, so both places blend three poses the same way.
]]
local function pairAt(alpha: number): (PoseConfig.Pose, PoseConfig.Pose, number)
	local t = math.clamp(alpha, 0, 1)
	local split = GaitConfig.SPRINT_FRACTION
	if t <= split then
		return WALK, SPRINT, if split > 1e-4 then t / split else 0
	end
	return SPRINT, DASH, math.clamp((t - split) / math.max(1e-4, 1 - split), 0, 1)
end

--[[
	One joint, blended across the three gaits into a single JointMotion.

	Returned as a JointMotion so the result flows through the same PosePlayback.PoseAt and
	AlphaAt everything else uses. Phase is taken from the first of the pair rather than
	interpolated: the three cycles share a phase structure by design, and sliding a phase
	as a player accelerated would drag the whole stride sideways.
]]
function GaitConfig.BlendJoint(jointName: string, alpha: number): PoseConfig.JointMotion?
	local from, to, t = pairAt(alpha)
	local a = motionIn(from, jointName)
	local b = motionIn(to, jointName)
	if a == nil or b == nil then
		return nil
	end

	return {
		Joint = jointName,
		Rest = a.Rest:Lerp(b.Rest, t),
		Peak = a.Peak:Lerp(b.Peak, t),
		Phase = a.Phase,
	}
end

function GaitConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	local function motionFor(pose: PoseConfig.Pose, jointName: string): PoseConfig.JointMotion?
		for _, motion in pose.Joints do
			if motion.Joint == jointName then
				return motion
			end
		end
		return nil
	end

	for _, gait in gaits do
		local pose = gait.Pose
		check(pose.Cycles == 1, `{gait.Id} is one cycle per stride`)

		for _, jointName in GaitConfig.Joints do
			local motion = motionFor(pose, jointName)
			check(motion ~= nil, `{gait.Id} drives {jointName}`)
			if motion ~= nil then
				for _, angles in { motion.Rest, motion.Peak } do
					check(
						math.abs(angles.X) <= 150 and math.abs(angles.Y) <= 150 and math.abs(angles.Z) <= 150,
						`{gait.Id} keeps {jointName} inside the joint ceiling`
					)
				end
				local phase = motion.Phase or 0
				check(phase >= 0 and phase < 1, `{gait.Id} phases {jointName} inside one cycle`)
			end
		end

		-- Opposition is the whole of a gait reading correctly, and it is one field. If a
		-- retune ever dropped a Phase the character would bunny-hop with both legs
		-- together, which is the kind of thing that looks like a physics bug.
		local rightHip = motionFor(pose, "RightHip")
		local leftHip = motionFor(pose, "LeftHip")
		check(
			rightHip ~= nil
				and leftHip ~= nil
				and math.abs(((leftHip.Phase or 0) - (rightHip.Phase or 0)) - 0.5) < 1e-6,
			`{gait.Id} puts its legs in opposition`
		)
		-- Arms oppose the same-side leg, so the right arm shares the left leg's phase.
		local rightShoulder = motionFor(pose, "RightShoulder")
		check(
			rightShoulder ~= nil
				and rightHip ~= nil
				and math.abs(((rightShoulder.Phase or 0) - (rightHip.Phase or 0)) - 0.5) < 1e-6,
			`{gait.Id} swings its arms against its legs`
		)
		-- Knees follow the thigh rather than leading it.
		local rightKnee = motionFor(pose, "RightKnee")
		check(
			rightKnee ~= nil and rightHip ~= nil and (rightKnee.Phase or 0) > (rightHip.Phase or 0),
			`{gait.Id} lets its knees lag its hips`
		)
	end

	-- The sprint has to actually be a harder version of the walk, or the blend does
	-- nothing and both speeds read the same.
	local walkHip = motionFor(WALK, "RightHip")
	local sprintHip = motionFor(SPRINT, "RightHip")
	check(
		walkHip ~= nil and sprintHip ~= nil and sprintHip.Peak.X > walkHip.Peak.X,
		"sprinting opens the stride further than walking"
	)
	local walkKnee = motionFor(WALK, "RightKnee")
	local sprintKnee = motionFor(SPRINT, "RightKnee")
	check(
		walkKnee ~= nil and sprintKnee ~= nil and sprintKnee.Peak.X < walkKnee.Peak.X,
		"sprinting lifts the knees higher than walking"
	)
	local walkElbow = motionFor(WALK, "RightElbow")
	local sprintElbow = motionFor(SPRINT, "RightElbow")
	check(
		walkElbow ~= nil and sprintElbow ~= nil and sprintElbow.Rest.X > walkElbow.Rest.X,
		"sprinting drives from a locked elbow"
	)

	-- Arms tuck in as speed rises. The shipped build had this backwards — a sprint held
	-- its arms wider than a walk — which read as windmilling. Asserting the relationship
	-- rather than the numbers means a future retune can move both and still be caught.
	local walkShoulder = motionFor(WALK, "RightShoulder")
	local sprintShoulder = motionFor(SPRINT, "RightShoulder")
	check(
		walkShoulder ~= nil
			and sprintShoulder ~= nil
			and math.abs(sprintShoulder.Rest.Z) < math.abs(walkShoulder.Rest.Z),
		"sprinting tucks its arms closer than walking"
	)
	check(
		walkShoulder ~= nil
			and sprintShoulder ~= nil
			and math.abs(sprintShoulder.Peak.Z) < math.abs(walkShoulder.Peak.Z),
		"sprinting keeps them tucked through the swing"
	)

	--[[
		Forward means the same thing here as it does in flight.

		This is the check that would have caught the sprint leaning backwards. Root X is
		negative-forward, which is not what the limb convention suggests, and nothing tied
		the gait's lean to the poses that already got it right — so a blind mistake in one
		file could not be contradicted by the other. Requiring FlightConfig for a test is
		a small price for an invariant that no amount of numeric verification would have
		surfaced.
	]]
	local glide = FlightConfig.Get("Glide")
	check(glide ~= nil, "FlightConfig still defines the glide pose")
	if glide ~= nil then
		check(glide.Angles.Root.X < 0, "flight's forward lean is negative on the root")
		check(Formulas.RunLean(1) < 0, "a sprint leans the same way flight does, not backwards")
	end

	-- Blend endpoints must be exact, or a walk sits a fraction away from the pose that
	-- was actually authored and every silhouette in the file is slightly wrong.
	local dashHip = motionFor(DASH, "RightHip")
	local atWalk = GaitConfig.BlendJoint("RightHip", 0)
	local atSprint = GaitConfig.BlendJoint("RightHip", GaitConfig.SPRINT_FRACTION)
	local atDash = GaitConfig.BlendJoint("RightHip", 1)
	check(
		atWalk ~= nil and walkHip ~= nil and atWalk.Peak == walkHip.Peak,
		"a zero blend is exactly the walk"
	)
	check(
		atSprint ~= nil and sprintHip ~= nil and atSprint.Peak == sprintHip.Peak,
		"the split lands exactly on the sprint"
	)
	check(
		atDash ~= nil and dashHip ~= nil and atDash.Peak == dashHip.Peak,
		"a full blend is exactly the dash"
	)
	check(GaitConfig.BlendJoint("NotAJoint", 0) == nil, "an unknown joint blends to nothing")
	-- Phase must survive the blend untouched. Interpolating it would slide the whole
	-- stride sideways as a player accelerated, which reads as the feet skating.
	check(
		atSprint ~= nil and walkHip ~= nil and (atSprint.Phase or 0) == (walkHip.Phase or 0),
		"blending does not shift the stride's phase"
	)

	--[[
		The dash is a ninja run, and these are the three things that make it one rather
		than a faster sprint.
	]]
	local walkShoulderRest = motionFor(WALK, "RightShoulder")
	local sprintShoulderRest = motionFor(SPRINT, "RightShoulder")
	local dashShoulder = motionFor(DASH, "RightShoulder")
	local dashElbow = motionFor(DASH, "RightElbow")
	-- Arms behind the body at *both* ends of the cycle. The walk and sprint swing
	-- through zero — forward and back — and a dash that did the same would just be a
	-- sprint with a deeper lean.
	check(
		dashShoulder ~= nil and dashShoulder.Rest.X < 0 and dashShoulder.Peak.X < 0,
		"the dash trails its arms behind it"
	)
	check(
		walkShoulderRest ~= nil and walkShoulderRest.Rest.X < 0 and walkShoulderRest.Peak.X > 0,
		"the walk swings its arms through"
	)
	-- And they barely move. Trailing arms that pumped would read as flailing.
	local function swingOf(motion: PoseConfig.JointMotion?): number
		return if motion ~= nil then math.abs(motion.Peak.X - motion.Rest.X) else 0
	end
	check(
		swingOf(dashShoulder) < swingOf(walkShoulderRest)
			and swingOf(dashShoulder) < swingOf(sprintShoulderRest),
		"the dash swings its arms least of the three"
	)
	-- Straight, not bent. A pair of lines behind the body rather than a pair of angles.
	local sprintElbowRest = motionFor(SPRINT, "RightElbow")
	check(
		dashElbow ~= nil and sprintElbowRest ~= nil and dashElbow.Rest.X < sprintElbowRest.Rest.X,
		"the dash locks its elbows straighter than the sprint drives them"
	)

	--[[
		Head pitch is the controller's, not the poses'.

		Neck X must be zero in every gait: GaitController cancels the lean on the neck so
		the character looks where they are going at any speed. A hand-written pitch here
		would fight it, which is exactly how the sprint ended up staring at the floor —
		Neck -6 against a -18 lean.
	]]
	for _, gait in gaits do
		local neck = motionFor(gait.Pose, "Neck")
		check(
			neck ~= nil and neck.Rest.X == 0 and neck.Peak.X == 0,
			`{gait.Id} leaves head pitch to the controller`
		)
	end

	-- Every gait runs the snappy curve. A pure cosine is the most symmetric, most
	-- realistic timing available, and anime poses played on it still read as realistic —
	-- see PosePlayback.AlphaAt.
	for _, gait in gaits do
		check(gait.Pose.MotionStyle == "Snapped", `{gait.Id} uses the snapped timing`)
	end

	-- The cap has to reach at least the sprint silhouette. Raise SPRINT_FRACTION past
	-- it and the pose would freeze part-way through walk-to-sprint, so every player at
	-- every power would look like they were jogging -- a change nobody would connect
	-- back to a constant in a different file.
	check(
		GaitConfig.MAX_POSE_BLEND >= GaitConfig.SPRINT_FRACTION,
		"the pose ceiling reaches at least the sprint silhouette"
	)
	check(
		GaitConfig.MAX_POSE_BLEND > 0 and GaitConfig.MAX_POSE_BLEND < 1,
		"the pose ceiling is a cap, not a fixed pose"
	)

	check(#GaitConfig.FOOTFALL_PHASES == 2, "a stride plants two feet")
	for _, footfall in GaitConfig.FOOTFALL_PHASES do
		check(footfall.Phase >= 0 and footfall.Phase < 1, `the {footfall.Side} footfall is inside the cycle`)
	end
	check(GaitConfig.BLEND_OUT_SECONDS > GaitConfig.BLEND_IN_SECONDS, "starting to move beats stopping")

	return failures
end

return GaitConfig
