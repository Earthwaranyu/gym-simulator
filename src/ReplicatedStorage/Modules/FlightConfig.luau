--!strict
--[[
	FlightConfig — what a flying body looks like, as joint angles.

	Same reasoning as PoseConfig and StrikeConfig, and the same axis conventions and
	~150 degree ceiling apply here unchanged: an uploaded animation belongs to some
	account, and this game owns everything it plays.

	Until now flight had no animation at all. FlightController puts the humanoid on
	PlatformStand and drives a LinearVelocity, so Roblox's own animator keeps playing
	the freefall clip and the avatar reads as a standing body sliding through the air.
	That is also why FlightController held the body rigidly upright — its comment said
	so outright, that "a rig with no flight animation looks like a falling body when
	pitched". These poses are what earn the right to pitch and bank at all.

	Deliberately not a PoseConfig entry. A Pose cycles between Rest and Peak forever on
	a machine's rep interval; flight has no reps, and what it wants to blend on is
	speed. Forcing it into that shape would mean inventing a fake rep interval and a
	pose that lies about what drives it.

	Three silhouettes, blended by how fast you are actually going:

	  Hover   — upright and idle, barely moving.
	  Glide   — leaning in, one arm starting to extend, legs beginning to trail.
	  Cruise  — the superhero: near-horizontal, leading fist forward, trailing arm
	            swept back, legs straight and together, head up.

	The band names are the strings FlightBand returns and the strings that cross the
	wire as the FlightState attribute, so a remote flier is posed from the same table.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

export type FlightPose = {
	Id: string,
	-- Where each joint sits, in degrees, same axes as a training pose.
	Angles: { [string]: Vector3 },
	-- Root translation, in studs, on the Motor6D transform. Purely cosmetic: the
	-- HumanoidRootPart never moves, so nothing here can push a flier through the world.
	Offset: Vector3,
}

local FlightConfig = {}

-- Every joint a flight pose drives. Listed once so a pose cannot silently forget one
-- and leave it to the freefall clip — the animator is still running underneath us, and
-- an unnamed joint is a joint it keeps.
FlightConfig.Joints = {
	"Root",
	"RightShoulder",
	"RightElbow",
	"LeftShoulder",
	"LeftElbow",
	"Waist",
	"Neck",
	"RightHip",
	"LeftHip",
	"RightKnee",
	"LeftKnee",
}

-- How long the pose takes to fade in on takeoff and out on landing. Long enough that
-- launching does not pop, short enough that landing hands the body back before the
-- humanoid's own walk cycle starts arguing with it.
FlightConfig.BLEND_IN_SECONDS = 0.28
FlightConfig.BLEND_OUT_SECONDS = 0.18

-- How quickly the pose chases a change of speed band. Slower than the velocity itself,
-- so the body settles into a cruise rather than snapping between silhouettes every
-- time a player taps a key.
FlightConfig.POSE_RESPONSIVENESS = 6

-- Idle motion. A hovering body with perfectly still joints is a mannequin, and the
-- thing being sold here is that the character is alive and holding themselves up.
FlightConfig.SWAY_SECONDS = 2.6
FlightConfig.SWAY_DEGREES = 4
-- The cruise silhouette barely breathes: at speed the read is a rigid arrow, and a
-- swaying one looks like it is struggling.
FlightConfig.CRUISE_SWAY_SCALE = 0.25

local function deg(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function pose(id: string, offset: Vector3, angles: { [string]: Vector3 }): FlightPose
	return { Id = id, Offset = offset, Angles = angles }
end

--[[
	Hovering. Upright, weight hanging, arms drifting a little away from the body the way
	they do when somebody is treading water. Knees slightly bent rather than locked,
	because straight legs on a stationary body read as a plank rather than as a person.
]]
local HOVER = pose("Hover", Vector3.new(0, 0, 0), {
	Root = deg(0, 0, 0),
	RightShoulder = deg(-8, 0, 18),
	RightElbow = deg(22, 0, 0),
	LeftShoulder = deg(-8, 0, -18),
	LeftElbow = deg(22, 0, 0),
	Waist = deg(-4, 0, 0),
	Neck = deg(2, 0, 0),
	RightHip = deg(-12, 0, 5),
	LeftHip = deg(-14, 0, -5),
	RightKnee = deg(-24, 0, 0),
	LeftKnee = deg(-18, 0, 0),
})

--[[
	Gliding. The transition, and the pose that does the most work — most flying happens
	at travelling speed rather than at either extreme. Leaning in, the right arm
	beginning to reach, the legs starting to stream out behind.
]]
local GLIDE = pose("Glide", Vector3.new(0, 0.15, -0.1), {
	Root = deg(-26, 0, 0),
	RightShoulder = deg(58, -6, 14),
	RightElbow = deg(34, 0, 0),
	LeftShoulder = deg(-34, 6, -22),
	LeftElbow = deg(40, 0, 0),
	Waist = deg(-10, 0, 0),
	Neck = deg(20, 0, 0),
	RightHip = deg(14, 0, 4),
	LeftHip = deg(10, 0, -4),
	RightKnee = deg(-26, 0, 0),
	LeftKnee = deg(-20, 0, 0),
})

--[[
	Cruising. One fist punched forward along the direction of travel, the other swept
	back flat against the body, legs straight and pressed together, head up and looking
	where it is going.

	The root pitch is what makes it read: the body lies down along its own velocity
	instead of standing up in it. FlightController supplies the rest by pitching and
	banking the whole character, and the two compose — this is the *shape*, that is the
	*attitude*.

	The leading shoulder stops at 132 rather than reaching a true straight-arm 180. The
	ceiling in PoseConfig's header is a hard limit, past which a BallSocketConstraint
	animates the long way round, and a fist that arrives by rotating backwards through
	the character's own chest is worse than one that is slightly bent.
]]
local CRUISE = pose("Cruise", Vector3.new(0, 0.3, -0.25), {
	Root = deg(-62, 0, 0),
	RightShoulder = deg(132, -4, 8),
	RightElbow = deg(8, 0, 0),
	LeftShoulder = deg(-52, 4, -12),
	LeftElbow = deg(14, 0, 0),
	Waist = deg(-14, 0, 0),
	Neck = deg(46, 0, 0),
	RightHip = deg(24, 0, 2),
	LeftHip = deg(22, 0, -2),
	RightKnee = deg(-8, 0, 0),
	LeftKnee = deg(-6, 0, 0),
})

local poses: { FlightPose } = { HOVER, GLIDE, CRUISE }

FlightConfig.List = poses

local byId: { [string]: FlightPose } = {}
for _, entry in poses do
	if byId[entry.Id] ~= nil then
		error(`[FlightConfig] Duplicate flight pose id "{entry.Id}"`)
	end
	byId[entry.Id] = entry
end

function FlightConfig.Get(poseId: string): FlightPose?
	return byId[poseId]
end

-- Stamped on the character by FlightService, watched by FlightPoseController and
-- VfxController. The value is a pose id, or nil when the character is on the ground.
-- Same trick as TrainingPose and StrikeAt: one attribute, and every client in the room
-- can animate somebody else's body without a byte of it being replicated.
FlightConfig.STATE_ATTRIBUTE = "FlightState"

--[[
	Blends two flight poses into a set of JointMotions ready for PosePlayback.

	Returned as JointMotion rather than as raw CFrames so the result goes through
	exactly the same PoseAt the training poses and the strikes do — one implementation
	of "angles and an offset become a CFrame", not three.

	Rest is the blended pose and Peak is the same thing, because a flight pose holds a
	shape rather than cycling through one. The sway is applied by the caller on top.
]]
function FlightConfig.Blend(from: FlightPose, to: FlightPose, alpha: number): { PoseConfig.JointMotion }
	local t = math.clamp(alpha, 0, 1)
	local motions: { PoseConfig.JointMotion } = {}
	for _, joint in FlightConfig.Joints do
		local a = from.Angles[joint] or Vector3.zero
		local b = to.Angles[joint] or Vector3.zero
		local blended = a:Lerp(b, t)
		local motion: PoseConfig.JointMotion = {
			Joint = joint,
			Rest = blended,
			Peak = blended,
		}
		if joint == "Root" then
			local offset = from.Offset:Lerp(to.Offset, t)
			motion.RestOffset = offset
			motion.PeakOffset = offset
		end
		table.insert(motions, motion)
	end
	return motions
end

function FlightConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	for _, entry in poses do
		for _, joint in FlightConfig.Joints do
			local angles: Vector3? = entry.Angles[joint]
			check(angles ~= nil, `{entry.Id} drives {joint}`)
			if angles ~= nil then
				-- The ceiling PoseConfig's header warns about. Past roughly 150 degrees a
				-- BallSocketConstraint animates backwards, and the limb arrives at the
				-- right pose by travelling through the character.
				check(
					math.abs(angles.X) <= 150 and math.abs(angles.Y) <= 150 and math.abs(angles.Z) <= 150,
					`{entry.Id} keeps {joint} inside the joint ceiling`
				)
			end
		end
	end

	check(byId.Hover ~= nil, "there is a hover pose")
	check(byId.Glide ~= nil, "there is a glide pose")
	check(byId.Cruise ~= nil, "there is a cruise pose")

	-- The silhouettes have to actually differ, and they have to differ in the right
	-- direction: this is a progression from standing up in the air to lying along the
	-- direction of travel, and a retune that flattened it would leave three poses that
	-- all read as hovering.
	local hoverPitch = byId.Hover.Angles.Root.X
	local glidePitch = byId.Glide.Angles.Root.X
	local cruisePitch = byId.Cruise.Angles.Root.X
	check(glidePitch < hoverPitch, "gliding leans further than hovering")
	check(cruisePitch < glidePitch, "cruising lies flatter than gliding")

	-- The leading arm is what makes the cruise read as a superhero rather than as a
	-- dive, so it is asserted rather than left to review.
	check(
		byId.Cruise.Angles.RightShoulder.X > byId.Glide.Angles.RightShoulder.X,
		"the cruise leads with its right fist"
	)
	check(byId.Cruise.Angles.RightKnee.X > byId.Hover.Angles.RightKnee.X, "the cruise straightens its legs")

	-- Blend has to be exact at both ends, or takeoff and top speed would each sit a
	-- fraction away from the pose that was actually authored.
	local atZero = FlightConfig.Blend(HOVER, CRUISE, 0)
	local atOne = FlightConfig.Blend(HOVER, CRUISE, 1)
	check(#atZero == #FlightConfig.Joints, "a blend drives every listed joint")
	for _, motion in atZero do
		if motion.Joint == "Root" then
			check(motion.Rest == HOVER.Angles.Root, "a zero blend is exactly the first pose")
		end
	end
	for _, motion in atOne do
		if motion.Joint == "Root" then
			check(motion.Rest == CRUISE.Angles.Root, "a full blend is exactly the second pose")
		end
	end
	local clamped = FlightConfig.Blend(HOVER, CRUISE, 9)
	for _, motion in clamped do
		if motion.Joint == "Root" then
			check(motion.Rest == CRUISE.Angles.Root, "a blend past one is clamped")
		end
	end

	-- A flight pose holds a shape rather than cycling through one, so Rest and Peak
	-- must agree. If they ever drifted apart the pose would silently start oscillating
	-- on whatever interval the playback happened to be given.
	for _, motion in atOne do
		check(motion.Rest == motion.Peak, `a flight pose holds {motion.Joint} still`)
	end

	check(
		FlightConfig.BLEND_OUT_SECONDS < FlightConfig.BLEND_IN_SECONDS,
		"landing releases faster than takeoff commits"
	)

	return failures
end

return FlightConfig
