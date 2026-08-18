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
	Walk — unhurried, wide-stanced, and heavier than the default.

	The width is in the Z on the hips: a bruiser does not walk with their feet in line.
	The waist counter-rotates against the hips and the neck counter-rotates against the
	waist, which is what keeps the head facing forward while the shoulders roll — the
	single detail that separates a walk with weight from a marionette.
]]
local WALK: PoseConfig.Pose = {
	Id = "GaitWalk",
	Cycles = 1,
	MotionStyle = "Continuous",
	Joints = {
		-- Rolls side to side. The vertical bob is not here: a body rises and falls once
		-- per *step* and a cycle is two steps, and one pose cannot run a single joint at
		-- double frequency. GaitController applies it.
		{ Joint = "Root", Rest = deg(0, 0, -2), Peak = deg(0, 0, 2) },
		{ Joint = "Waist", Rest = deg(2, -7, 0), Peak = deg(2, 7, 0) },
		{ Joint = "Neck", Rest = deg(0, 4, 0), Peak = deg(0, -4, 0) },

		-- Arms oppose the same-side leg, so the right arm carries the left leg's phase.
		{ Joint = "RightShoulder", Rest = deg(-18, 0, 12), Peak = deg(26, 0, 14), Phase = 0.5 },
		{ Joint = "LeftShoulder", Rest = deg(-18, 0, -12), Peak = deg(26, 0, -14) },
		{ Joint = "RightElbow", Rest = deg(14, 0, 0), Peak = deg(32, 0, 0), Phase = 0.5 },
		{ Joint = "LeftElbow", Rest = deg(14, 0, 0), Peak = deg(32, 0, 0) },

		{ Joint = "RightHip", Rest = deg(-22, 0, 6), Peak = deg(30, 0, 6) },
		{ Joint = "LeftHip", Rest = deg(-22, 0, -6), Peak = deg(30, 0, -6), Phase = 0.5 },
		-- Knees lag the hips by a fifth of a cycle: the thigh swings, then the shin
		-- follows. Leading or matching the hip is what makes a leg look like a plank.
		{ Joint = "RightKnee", Rest = deg(-8, 0, 0), Peak = deg(-52, 0, 0), Phase = 0.2 },
		{ Joint = "LeftKnee", Rest = deg(-8, 0, 0), Peak = deg(-52, 0, 0), Phase = 0.7 },
		{ Joint = "RightAnkle", Rest = deg(-6, 0, 0), Peak = deg(10, 0, 0), Phase = 0.15 },
		{ Joint = "LeftAnkle", Rest = deg(-6, 0, 0), Peak = deg(10, 0, 0), Phase = 0.65 },
	},
}

--[[
	Sprint — the same skeleton driven much harder.

	Same phases, bigger angles: the stride opens up, the knees come high, the arms drive
	from a locked near-ninety elbow instead of swinging loose, and the waist rotation
	roughly doubles. The forward lean is not here either — GaitController applies it to
	the root, because it has to grow smoothly with speed rather than switch on when the
	sprint pose takes over.
]]
local SPRINT: PoseConfig.Pose = {
	Id = "GaitSprint",
	Cycles = 1,
	MotionStyle = "Continuous",
	Joints = {
		{ Joint = "Root", Rest = deg(0, 0, -3), Peak = deg(0, 0, 3) },
		{ Joint = "Waist", Rest = deg(6, -13, 0), Peak = deg(6, 13, 0) },
		-- Head held up against a body that is leaning hard, so the character is looking
		-- where they are going rather than at the floor.
		{ Joint = "Neck", Rest = deg(-6, 6, 0), Peak = deg(-6, -6, 0) },

		{ Joint = "RightShoulder", Rest = deg(-52, 0, 16), Peak = deg(62, 0, 18), Phase = 0.5 },
		{ Joint = "LeftShoulder", Rest = deg(-52, 0, -16), Peak = deg(62, 0, -18) },
		-- Held near ninety through the whole cycle. A sprinter's elbow angle barely
		-- changes; it is the shoulder that drives, and a flapping forearm reads as a jog.
		{ Joint = "RightElbow", Rest = deg(78, 0, 0), Peak = deg(96, 0, 0), Phase = 0.5 },
		{ Joint = "LeftElbow", Rest = deg(78, 0, 0), Peak = deg(96, 0, 0) },

		{ Joint = "RightHip", Rest = deg(-42, 0, 5), Peak = deg(58, 0, 5) },
		{ Joint = "LeftHip", Rest = deg(-42, 0, -5), Peak = deg(58, 0, -5), Phase = 0.5 },
		{ Joint = "RightKnee", Rest = deg(-18, 0, 0), Peak = deg(-112, 0, 0), Phase = 0.2 },
		{ Joint = "LeftKnee", Rest = deg(-18, 0, 0), Peak = deg(-112, 0, 0), Phase = 0.7 },
		{ Joint = "RightAnkle", Rest = deg(-14, 0, 0), Peak = deg(22, 0, 0), Phase = 0.15 },
		{ Joint = "LeftAnkle", Rest = deg(-14, 0, 0), Peak = deg(22, 0, 0), Phase = 0.65 },
	},
}

local gaits: { Gait } = {
	{ Id = "Walk", Pose = WALK },
	{ Id = "Sprint", Pose = SPRINT },
}

GaitConfig.List = gaits
GaitConfig.Walk = WALK
GaitConfig.Sprint = SPRINT

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
function GaitConfig.BlendJoint(jointName: string, alpha: number): PoseConfig.JointMotion?
	local walk: PoseConfig.JointMotion? = nil
	local sprint: PoseConfig.JointMotion? = nil
	for _, motion in WALK.Joints do
		if motion.Joint == jointName then
			walk = motion
			break
		end
	end
	for _, motion in SPRINT.Joints do
		if motion.Joint == jointName then
			sprint = motion
			break
		end
	end
	if walk == nil or sprint == nil then
		return nil
	end

	local t = math.clamp(alpha, 0, 1)
	return {
		Joint = jointName,
		Rest = walk.Rest:Lerp(sprint.Rest, t),
		Peak = walk.Peak:Lerp(sprint.Peak, t),
		Phase = walk.Phase,
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
		-- Continuous is what makes it a cosine with no dwell. Controlled would give a
		-- gait the four-beat rhythm of a bench press, which stops dead at both ends.
		check(pose.MotionStyle == "Continuous", `{gait.Id} flows rather than settling`)

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

	-- Blend endpoints must be exact, or a walk sits a fraction away from the pose that
	-- was actually authored and every silhouette in the file is slightly wrong.
	local atWalk = GaitConfig.BlendJoint("RightHip", 0)
	local atSprint = GaitConfig.BlendJoint("RightHip", 1)
	check(
		atWalk ~= nil and walkHip ~= nil and atWalk.Peak == walkHip.Peak,
		"a zero blend is exactly the walk"
	)
	check(
		atSprint ~= nil and sprintHip ~= nil and atSprint.Peak == sprintHip.Peak,
		"a full blend is exactly the sprint"
	)
	check(GaitConfig.BlendJoint("NotAJoint", 0) == nil, "an unknown joint blends to nothing")
	-- Phase must survive the blend untouched. Interpolating it would slide the whole
	-- stride sideways as a player accelerated, which reads as the feet skating.
	check(
		atSprint ~= nil and walkHip ~= nil and (atSprint.Phase or 0) == (walkHip.Phase or 0),
		"blending does not shift the stride's phase"
	)

	check(#GaitConfig.FOOTFALL_PHASES == 2, "a stride plants two feet")
	for _, footfall in GaitConfig.FOOTFALL_PHASES do
		check(footfall.Phase >= 0 and footfall.Phase < 1, `the {footfall.Side} footfall is inside the cycle`)
	end
	check(GaitConfig.BLEND_OUT_SECONDS > GaitConfig.BLEND_IN_SECONDS, "starting to move beats stopping")

	return failures
end

return GaitConfig
