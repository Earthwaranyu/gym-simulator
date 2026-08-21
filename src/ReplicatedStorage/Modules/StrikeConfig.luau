--!strict
--[[
	StrikeConfig — the combat animations, as joint angles.

	Same idea as PoseConfig and for the same reason: an uploaded animation is an asset
	owned by some account, and this game owns everything it plays. See that module's
	header for the axis conventions and the ~150 degree ceiling, both of which apply
	here unchanged.

	One difference, and it is the whole reason this is a separate module. A training
	pose loops: two states, eased back and forth, forever, at the machine's rep pace.
	A strike happens once and is over. It can contain any number of coil, contact and
	recovery stages, plus synchronized contact markers for server damage.

	The anime read comes from the timing far more than the angles. A real punch is
	roughly symmetric; the cartoon version is a slow drawn-back coil and then a
	contact that arrives in two frames, held a beat at full extension while the world
	catches up. Hence Windup taking well over half the clip and Contact almost none of
	it: the snap is the whole gag.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)
local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

export type StrikeStage = {
	-- Fraction of the whole strike this stage runs for. The stages sum to 1.
	Portion: number,
	-- Timing curve for this stage. Coil settles smoothly, Snap explodes toward contact,
	-- and Recover eases the body back without a robotic stop.
	Easing: string?,
	-- Where each joint is by the end of this stage, in degrees, same axes as a pose.
	Joints: { PoseConfig.JointMotion },
}

--[[
	One world effect, and when in the clip it happens.

	Effect names a VfxConfig entry. Attach says what the effect is anchored to:
	the character's root, the hand that is throwing the strike, or the ground
	directly beneath the character at that moment.
]]
export type StrikeVfx = {
	At: number,
	Effect: string,
	-- Which hand matters more than it looks: the middle contact of Punch's combo is a
	-- *left* cross, and a helper that only ever resolved the right fist would put its
	-- effect on the wrong arm.
	Attach: ("Root" | "RightHand" | "LeftHand" | "Ground")?,
}

export type Strike = {
	Id: string,
	-- Seconds end to end. Shorter than the ability's cooldown, so the body is back
	-- to neutral before the next punch can be thrown.
	Duration: number,
	-- Normalized points in the clip where an impact occurs. Combat reads the same
	-- markers as presentation, so a combo cannot damage before its fist arrives.
	Contacts: { number },
	Stages: { StrikeStage },
	-- World effects, timed against the same clip as the joints. VfxController reads
	-- this off the same attribute StrikeController watches, so an effect's timing
	-- lives beside the frame it is meant to land on rather than in a second table
	-- that has to be kept in sync by hand.
	--
	-- StrikeController deliberately ignores it: the body and the fireworks are
	-- separate concerns and a client with effects turned down still throws the punch.
	Vfx: { StrikeVfx }?,
}

local function deg(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

--[[
	One stage's worth of joint targets.

	Written as JointMotion so it can be handed straight to PosePlayback.PoseAt, which
	is the same function the training poses go through. Rest is where the joint starts
	the stage and Peak where it ends; the player eases between them exactly as it does
	on a machine.
]]
local function stage(portion: number, easing: string, joints: { PoseConfig.JointMotion }): StrikeStage
	return { Portion = portion, Easing = easing, Joints = joints }
end

type CombatPose = {
	Angles: { [string]: Vector3 },
	Offset: Vector3,
}

local JOINTS = {
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

local function combatPose(offset: Vector3, angles: { [string]: Vector3 }): CombatPose
	return { Angles = angles, Offset = offset }
end

local function transition(portion: number, easing: string, from: CombatPose, to: CombatPose): StrikeStage
	local motions: { PoseConfig.JointMotion } = {}
	for _, joint in JOINTS do
		local motion: PoseConfig.JointMotion = {
			Joint = joint,
			Rest = from.Angles[joint],
			Peak = to.Angles[joint],
		}
		if joint == "Root" then
			motion.RestOffset = from.Offset
			motion.PeakOffset = to.Offset
		end
		table.insert(motions, motion)
	end
	return stage(portion, easing, motions)
end

local NEUTRAL = combatPose(Vector3.zero, {
	Root = deg(0, 0, 0),
	RightShoulder = deg(0, 0, 0),
	RightElbow = deg(0, 0, 0),
	LeftShoulder = deg(0, 0, 0),
	LeftElbow = deg(0, 0, 0),
	Waist = deg(0, 0, 0),
	Neck = deg(0, 0, 0),
	RightHip = deg(0, 0, 0),
	LeftHip = deg(0, 0, 0),
	RightKnee = deg(0, 0, 0),
	LeftKnee = deg(0, 0, 0),
})

local RIGHT_COIL = combatPose(Vector3.new(0, -0.05, 0.08), {
	Root = deg(1, -6, 0),
	RightShoulder = deg(-25, -6, 24),
	RightElbow = deg(112, 0, 0),
	LeftShoulder = deg(56, 4, -36),
	LeftElbow = deg(116, 0, 0),
	Waist = deg(-3, -18, -2),
	Neck = deg(2, 7, 0),
	RightHip = deg(-10, 0, 9),
	LeftHip = deg(11, 0, -8),
	RightKnee = deg(-20, 0, 0),
	LeftKnee = deg(-15, 0, 0),
})

local RIGHT_CONTACT = combatPose(Vector3.new(0, 0, -0.28), {
	Root = deg(-2, 8, 0),
	RightShoulder = deg(102, 3, -5),
	RightElbow = deg(3, 0, 0),
	LeftShoulder = deg(55, -2, -40),
	LeftElbow = deg(122, 0, 0),
	Waist = deg(3, 24, 3),
	Neck = deg(-2, -7, 0),
	RightHip = deg(9, 0, 7),
	LeftHip = deg(-7, 0, -8),
	RightKnee = deg(-10, 0, 0),
	LeftKnee = deg(-12, 0, 0),
})

local LEFT_COIL = combatPose(Vector3.new(0, -0.04, 0.05), {
	Root = deg(1, 6, 0),
	RightShoulder = deg(56, -4, 36),
	RightElbow = deg(116, 0, 0),
	LeftShoulder = deg(-25, 6, -24),
	LeftElbow = deg(112, 0, 0),
	Waist = deg(-3, 18, 2),
	Neck = deg(2, -7, 0),
	RightHip = deg(11, 0, 8),
	LeftHip = deg(-10, 0, -9),
	RightKnee = deg(-15, 0, 0),
	LeftKnee = deg(-20, 0, 0),
})

local LEFT_CONTACT = combatPose(Vector3.new(0, 0, -0.3), {
	Root = deg(-2, -9, 0),
	RightShoulder = deg(55, 2, 40),
	RightElbow = deg(122, 0, 0),
	LeftShoulder = deg(102, -3, 5),
	LeftElbow = deg(3, 0, 0),
	Waist = deg(3, -27, -3),
	Neck = deg(-2, 8, 0),
	RightHip = deg(-8, 0, 8),
	LeftHip = deg(10, 0, -7),
	RightKnee = deg(-12, 0, 0),
	LeftKnee = deg(-10, 0, 0),
})

local FINISH_COIL = combatPose(Vector3.new(0, -0.1, 0.12), {
	Root = deg(3, -10, 0),
	RightShoulder = deg(-38, -8, 28),
	RightElbow = deg(126, 0, 0),
	LeftShoulder = deg(58, 4, -38),
	LeftElbow = deg(120, 0, 0),
	Waist = deg(-5, -30, -3),
	Neck = deg(3, 10, 0),
	RightHip = deg(-16, 0, 11),
	LeftHip = deg(16, 0, -9),
	RightKnee = deg(-26, 0, 0),
	LeftKnee = deg(-17, 0, 0),
})

local FINISH_CONTACT = combatPose(Vector3.new(0, 0.02, -0.48), {
	Root = deg(-4, 12, 0),
	RightShoulder = deg(110, 4, -7),
	RightElbow = deg(2, 0, 0),
	LeftShoulder = deg(55, -2, -42),
	LeftElbow = deg(124, 0, 0),
	Waist = deg(5, 34, 4),
	Neck = deg(-3, -10, 0),
	RightHip = deg(14, 0, 7),
	LeftHip = deg(-10, 0, -8),
	RightKnee = deg(-8, 0, 0),
	LeftKnee = deg(-12, 0, 0),
})

--[[
	Ground Slam.

	A crouch, a leap, a hang at the top, and everything coming down at once. The root
	offset is what sells the leap: it is a Motor6D transform, so the avatar visually
	rises nearly three studs while the HumanoidRootPart never leaves the floor — no
	physics, nothing to desync, and nothing that can drop somebody through the map.

	The hang is a separate stage rather than a longer coil because the pause at the
	apex is the whole read. Without it the leap and the smash blend into one arc and
	the move looks like a fast crouch.
]]
local SLAM_LOAD = combatPose(Vector3.new(0, -0.55, 0.1), {
	Root = deg(6, 0, 0),
	RightShoulder = deg(-30, 0, 10),
	RightElbow = deg(95, 0, 0),
	LeftShoulder = deg(-30, 0, -10),
	LeftElbow = deg(95, 0, 0),
	Waist = deg(-14, 0, 0),
	Neck = deg(6, 0, 0),
	RightHip = deg(-32, 0, 7),
	LeftHip = deg(-32, 0, -7),
	RightKnee = deg(-62, 0, 0),
	LeftKnee = deg(-62, 0, 0),
})

local SLAM_APEX = combatPose(Vector3.new(0, 2.8, 0), {
	Root = deg(-8, 0, 0),
	-- Not a true overhead reach: the ~150 degree ceiling in PoseConfig's header is a
	-- hard limit, past which a BallSocketConstraint animates the long way round. 138
	-- is as close to overhead as the rig can be driven and still read correctly.
	RightShoulder = deg(138, 0, 14),
	RightElbow = deg(30, 0, 0),
	LeftShoulder = deg(138, 0, -14),
	LeftElbow = deg(30, 0, 0),
	Waist = deg(-12, 0, 0),
	Neck = deg(-10, 0, 0),
	RightHip = deg(-45, 0, 8),
	LeftHip = deg(-45, 0, -8),
	RightKnee = deg(-88, 0, 0),
	LeftKnee = deg(-88, 0, 0),
})

local SLAM_HANG = combatPose(Vector3.new(0, 3.05, 0.05), {
	Root = deg(-11, 0, 0),
	RightShoulder = deg(144, 0, 16),
	RightElbow = deg(38, 0, 0),
	LeftShoulder = deg(144, 0, -16),
	LeftElbow = deg(38, 0, 0),
	Waist = deg(-16, 0, 0),
	Neck = deg(-14, 0, 0),
	RightHip = deg(-52, 0, 9),
	LeftHip = deg(-52, 0, -9),
	RightKnee = deg(-96, 0, 0),
	LeftKnee = deg(-96, 0, 0),
})

local SLAM_IMPACT = combatPose(Vector3.new(0, -0.85, -0.2), {
	Root = deg(14, 0, 0),
	RightShoulder = deg(18, 0, 6),
	RightElbow = deg(12, 0, 0),
	LeftShoulder = deg(18, 0, -6),
	LeftElbow = deg(12, 0, 0),
	Waist = deg(26, 0, 0),
	Neck = deg(-14, 0, 0),
	RightHip = deg(-40, 0, 10),
	LeftHip = deg(-40, 0, -10),
	RightKnee = deg(-84, 0, 0),
	LeftKnee = deg(-84, 0, 0),
})

-- The beat after the fists land. Barely different from the impact itself, on purpose:
-- holding a pose that is almost but not quite the contact frame is what makes weight
-- read, where snapping straight back to neutral makes the same angles look weightless.
local SLAM_HOLD = combatPose(Vector3.new(0, -0.7, -0.16), {
	Root = deg(11, 0, 0),
	RightShoulder = deg(14, 0, 7),
	RightElbow = deg(16, 0, 0),
	LeftShoulder = deg(14, 0, -7),
	LeftElbow = deg(16, 0, 0),
	Waist = deg(21, 0, 0),
	Neck = deg(-11, 0, 0),
	RightHip = deg(-34, 0, 9),
	LeftHip = deg(-34, 0, -9),
	RightKnee = deg(-70, 0, 0),
	LeftKnee = deg(-70, 0, 0),
})

--[[
	Hard Punch.

	Punch's silhouettes, exaggerated and slowed. The wind is deliberately almost half
	the clip: this is the move Block exists to answer, and a heavy hit that cannot be
	seen coming is not a read, it is a coin flip. HEAVY_LOAD is a second, smaller coil
	at the end of the wind, so the arm visibly stops at full tension before release.
]]
local HEAVY_COIL = combatPose(Vector3.new(0, -0.12, 0.22), {
	Root = deg(2, -16, 0),
	RightShoulder = deg(-46, -10, 30),
	RightElbow = deg(132, 0, 0),
	LeftShoulder = deg(62, 6, -40),
	LeftElbow = deg(118, 0, 0),
	Waist = deg(-6, -40, -4),
	Neck = deg(3, 16, 0),
	RightHip = deg(-20, 0, 13),
	LeftHip = deg(20, 0, -11),
	RightKnee = deg(-32, 0, 0),
	LeftKnee = deg(-20, 0, 0),
})

local HEAVY_LOAD = combatPose(Vector3.new(0, -0.16, 0.28), {
	Root = deg(3, -20, 0),
	RightShoulder = deg(-52, -12, 32),
	RightElbow = deg(138, 0, 0),
	LeftShoulder = deg(64, 7, -42),
	LeftElbow = deg(122, 0, 0),
	Waist = deg(-7, -46, -5),
	Neck = deg(4, 19, 0),
	RightHip = deg(-24, 0, 14),
	LeftHip = deg(23, 0, -12),
	RightKnee = deg(-36, 0, 0),
	LeftKnee = deg(-22, 0, 0),
})

local HEAVY_CONTACT = combatPose(Vector3.new(0, 0.03, -0.62), {
	Root = deg(-5, 16, 0),
	RightShoulder = deg(118, 5, -8),
	RightElbow = deg(2, 0, 0),
	LeftShoulder = deg(52, -3, -44),
	LeftElbow = deg(128, 0, 0),
	Waist = deg(6, 42, 5),
	Neck = deg(-4, -13, 0),
	RightHip = deg(18, 0, 7),
	LeftHip = deg(-12, 0, -9),
	RightKnee = deg(-6, 0, 0),
	LeftKnee = deg(-14, 0, 0),
})

-- Past the target. A heavy punch that stops exactly where it connects looks like it
-- was caught; one that over-rotates looks like it went through.
local HEAVY_FOLLOW = combatPose(Vector3.new(0, 0, -0.7), {
	Root = deg(-7, 26, 0),
	RightShoulder = deg(112, 8, -14),
	RightElbow = deg(12, 0, 0),
	LeftShoulder = deg(46, -4, -46),
	LeftElbow = deg(124, 0, 0),
	Waist = deg(8, 52, 6),
	Neck = deg(-6, -18, 0),
	RightHip = deg(22, 0, 6),
	LeftHip = deg(-16, 0, -8),
	RightKnee = deg(-10, 0, 0),
	LeftKnee = deg(-18, 0, 0),
})

--[[
	The monster swings. Two of them, both authored heavier and slower than anything a
	player throws.

	A goblin has no combat training and no reach discipline: it winds one arm back past
	its own shoulder line, drops its guard completely and throws its whole body at you.
	That readability is the point — the wind-up is the only warning a player gets, and it
	has to be legible from behind as well as from in front.

	These reuse the player's joint vocabulary exactly, so they need no new machinery. The
	mob rig has no ankles; those joints resolve to nil and are skipped.
]]
local MOB_READY = combatPose(Vector3.new(0, -0.1, 0), {
	Root = deg(2, 0, 0),
	RightShoulder = deg(-14, 0, 16),
	RightElbow = deg(38, 0, 0),
	LeftShoulder = deg(-10, 0, -14),
	LeftElbow = deg(32, 0, 0),
	Waist = deg(4, 0, 0),
	Neck = deg(-4, 0, 0),
	RightHip = deg(-6, 0, 0),
	LeftHip = deg(4, 0, 0),
	RightKnee = deg(-14, 0, 0),
	LeftKnee = deg(-10, 0, 0),
})

local MOB_WIND = combatPose(Vector3.new(0, -0.22, -0.18), {
	Root = deg(-6, -26, 0),
	-- Past the shoulder line, which a trained fighter would never do. It is what makes
	-- the swing read from any angle.
	RightShoulder = deg(52, 0, 62),
	RightElbow = deg(74, 0, 0),
	LeftShoulder = deg(-28, 0, -30),
	LeftElbow = deg(18, 0, 0),
	Waist = deg(-8, -20, 0),
	Neck = deg(6, -14, 0),
	RightHip = deg(-14, 0, 0),
	LeftHip = deg(10, 0, 0),
	RightKnee = deg(-26, 0, 0),
	LeftKnee = deg(-8, 0, 0),
})

local MOB_CONTACT = combatPose(Vector3.new(0, -0.05, 0.4), {
	Root = deg(8, 30, 0),
	RightShoulder = deg(-42, 0, -18),
	RightElbow = deg(12, 0, 0),
	LeftShoulder = deg(20, 0, 34),
	LeftElbow = deg(40, 0, 0),
	Waist = deg(12, 24, 0),
	Neck = deg(-8, 16, 0),
	RightHip = deg(12, 0, 0),
	LeftHip = deg(-12, 0, 0),
	RightKnee = deg(-8, 0, 0),
	LeftKnee = deg(-22, 0, 0),
})

-- Both arms overhead, body stretched tall. The silhouette IS the telegraph, so it is
-- deliberately the opposite shape to everything else the creature does.
local MOB_RAISE = combatPose(Vector3.new(0, 0.25, -0.1), {
	Root = deg(-10, 0, 0),
	RightShoulder = deg(-142, 0, 22),
	RightElbow = deg(28, 0, 0),
	LeftShoulder = deg(-142, 0, -22),
	LeftElbow = deg(28, 0, 0),
	Waist = deg(-12, 0, 0),
	Neck = deg(-18, 0, 0),
	RightHip = deg(-4, 0, 0),
	LeftHip = deg(-4, 0, 0),
	RightKnee = deg(-6, 0, 0),
	LeftKnee = deg(-6, 0, 0),
})

local MOB_SMASH = combatPose(Vector3.new(0, -0.7, 0.3), {
	Root = deg(26, 0, 0),
	RightShoulder = deg(-8, 0, 6),
	RightElbow = deg(6, 0, 0),
	LeftShoulder = deg(-8, 0, -6),
	LeftElbow = deg(6, 0, 0),
	Waist = deg(30, 0, 0),
	Neck = deg(-24, 0, 0),
	RightHip = deg(28, 0, 0),
	LeftHip = deg(28, 0, 0),
	RightKnee = deg(-64, 0, 0),
	LeftKnee = deg(-64, 0, 0),
})

local strikes: { Strike } = {
	--[[
		The punch chain: one click, one swing.

		This used to be a single 0.9-second clip that landed all three contacts on its
		own, so a player pressed once and watched. Three separate strikes means the
		player throws each punch, and the chain is something they do rather than
		something the game does to them.

		The poses are unchanged — these are the same coils and contacts the old combo
		walked through, regrouped one swing at a time. What is new is that each ends by
		returning to neutral, because a swing now has to be able to be the last one.
		Punch.luau decides which of the three to stamp from the player's place in the
		chain.
	]]
	{
		-- The jab. Right hand, fastest thing in the game to land, and the swing a chain
		-- starts from.
		Id = "PunchJab",
		Duration = 0.34,
		Contacts = { 0.5 },
		Stages = {
			transition(0.3, "Coil", NEUTRAL, RIGHT_COIL),
			transition(0.2, "Snap", RIGHT_COIL, RIGHT_CONTACT),
			transition(0.5, "Recover", RIGHT_CONTACT, NEUTRAL),
		},
	},
	{
		-- The cross. Left hand, so the chain alternates rather than hammering one arm.
		Id = "PunchCross",
		Duration = 0.34,
		Contacts = { 0.5 },
		Stages = {
			transition(0.3, "Coil", NEUTRAL, LEFT_COIL),
			transition(0.2, "Snap", LEFT_COIL, LEFT_CONTACT),
			transition(0.5, "Recover", LEFT_CONTACT, NEUTRAL),
		},
	},
	{
		-- The finisher. Longer than the other two, and most of the extra length is in
		-- the recovery: reaching the end of a chain should visibly cost something, and
		-- the swing that hits hardest is the one you are most exposed after.
		Id = "PunchFinish",
		Duration = 0.42,
		Contacts = { 0.46 },
		Stages = {
			transition(0.28, "Coil", NEUTRAL, FINISH_COIL),
			transition(0.18, "Snap", FINISH_COIL, FINISH_CONTACT),
			transition(0.54, "Recover", FINISH_CONTACT, NEUTRAL),
		},
	},
	{
		-- Ground Slam. One contact, on everybody in a radius, two thirds of the way
		-- through the clip — the leap and the hang before it are the window an
		-- opponent gets to walk out of the circle or put a guard up.
		Id = "GroundSlam",
		Duration = 1.15,
		Contacts = { 0.62 },
		Stages = {
			transition(0.16, "Coil", NEUTRAL, SLAM_LOAD),
			transition(0.22, "Recover", SLAM_LOAD, SLAM_APEX),
			transition(0.12, "Coil", SLAM_APEX, SLAM_HANG),
			transition(0.12, "Snap", SLAM_HANG, SLAM_IMPACT),
			transition(0.1, "Recover", SLAM_IMPACT, SLAM_HOLD),
			transition(0.28, "Recover", SLAM_HOLD, NEUTRAL),
		},
		Vfx = {
			-- Starts with the crouch, not the leap: the telegraph is the point, and
			-- the ring on the floor is what tells an opponent how far to run.
			{ At = 0.16, Effect = "SlamCharge", Attach = "Ground" :: "Ground" },
			{ At = 0.62, Effect = "SlamImpact", Attach = "Ground" :: "Ground" },
		},
	},
	{
		-- Hard Punch. Nearly half the clip is wind-up, which is what makes it the
		-- move Block answers.
		Id = "HardPunch",
		Duration = 0.85,
		Contacts = { 0.55 },
		Stages = {
			transition(0.34, "Coil", NEUTRAL, HEAVY_COIL),
			transition(0.13, "Coil", HEAVY_COIL, HEAVY_LOAD),
			transition(0.08, "Snap", HEAVY_LOAD, HEAVY_CONTACT),
			transition(0.12, "Recover", HEAVY_CONTACT, HEAVY_FOLLOW),
			transition(0.33, "Recover", HEAVY_FOLLOW, NEUTRAL),
		},
		Vfx = {
			-- Only the wind-up. The impact used to be scheduled here too, which meant a
			-- heavy swung at empty air produced a full impact flash against nothing —
			-- the swing is stamped whether or not it connects, so anything driven off it
			-- fires on a whiff. Impacts are driven from the victim now; see
			-- FlinchConfig's header.
			{ At = 0.2, Effect = "HeavyCharge", Attach = "RightHand" :: "RightHand" },
		},
	},
	{
		-- The ordinary monster swing. Slower than a player's jab on purpose: a goblin
		-- landing a hit should feel like something you let happen.
		Id = "MobSwing",
		Duration = 1.1,
		Contacts = { 0.58 },
		Stages = {
			transition(0.2, "Coil", NEUTRAL, MOB_READY),
			transition(0.24, "Coil", MOB_READY, MOB_WIND),
			transition(0.14, "Snap", MOB_WIND, MOB_CONTACT),
			transition(0.42, "Recover", MOB_CONTACT, NEUTRAL),
		},
	},
	{
		-- The boss's heavy. Over a third of it is the raise, because that window is what
		-- a player is meant to spend walking out of the ring.
		Id = "MobUltimate",
		Duration = 2,
		Contacts = { 0.66 },
		Stages = {
			transition(0.14, "Coil", NEUTRAL, MOB_READY),
			transition(0.24, "Coil", MOB_READY, MOB_RAISE),
			-- The hold at the top. Nothing moves, which is what makes the drop land.
			transition(0.16, "Recover", MOB_RAISE, MOB_RAISE),
			transition(0.12, "Snap", MOB_RAISE, MOB_SMASH),
			transition(0.34, "Recover", MOB_SMASH, NEUTRAL),
		},
		Vfx = {
			{ At = 0.38, Effect = "SlamCharge", Attach = "Ground" :: "Ground" },
			{ At = 0.66, Effect = "SlamImpact", Attach = "Ground" :: "Ground" },
		},
	},
}

local StrikeConfig = {}

StrikeConfig.List = strikes

-- Attribute the server stamps on an attacker's character: the server timestamp of the
-- swing. Every client watches it and plays the strike, which is how one player's punch
-- is visible to the whole room — the same trick TrainingPose uses, and for the same
-- reason. A number rather than a boolean so two punches in a row are two events.
StrikeConfig.STRIKE_ATTRIBUTE = "StrikeAt"
StrikeConfig.STRIKE_ID_ATTRIBUTE = "StrikeId"

local byId: { [string]: Strike } = {}
for _, strike in strikes do
	if byId[strike.Id] ~= nil then
		error(`[StrikeConfig] Duplicate strike id "{strike.Id}"`)
	end
	byId[strike.Id] = strike
end

function StrikeConfig.Get(strikeId: string): Strike?
	return byId[strikeId]
end

function StrikeConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	for _, strike in strikes do
		local total = 0
		local seen: { [string]: boolean } = {}
		for _, strikeStage in strike.Stages do
			total += strikeStage.Portion
			check(strikeStage.Portion > 0, `{strike.Id} stages have positive duration`)
			for _, motion in strikeStage.Joints do
				seen[motion.Joint] = true
			end
		end
		check(math.abs(total - 1) < 1e-6, `{strike.Id} stage portions total one`)
		check(#strike.Contacts > 0, `{strike.Id} has at least one synchronized contact`)
		local previousContact = 0
		for _, contact in strike.Contacts do
			check(
				contact > previousContact and contact < 1,
				`{strike.Id} contacts are ordered inside the clip`
			)
			previousContact = contact
		end
		check(seen.Root == true, `{strike.Id} moves the root`)
		check(seen.Waist == true, `{strike.Id} transfers force through the waist`)
		check(seen.RightShoulder == true and seen.RightElbow == true, `{strike.Id} drives its punching arm`)
	end
	-- The punch chain. One click is one swing now, so each of the three lands exactly
	-- once; the old single Punch strike landed three times on its own.
	local jab = byId.PunchJab
	local finish = byId.PunchFinish
	for _, id in { "PunchJab", "PunchCross", "PunchFinish" } do
		local strike = byId[id]
		check(strike ~= nil, `the chain defines {id}`)
		if strike ~= nil then
			check(#strike.Contacts == 1, `{id} lands once`)
		end
	end
	-- Committing to the end of the chain has to cost something, and the cost is the
	-- finisher's longer recovery. A retune that made it the shortest swing would make
	-- the chain strictly better than mashing the jab.
	check(
		jab ~= nil and finish ~= nil and finish.Duration > jab.Duration,
		"the finisher commits for longer than the jab"
	)

	local slam = byId.GroundSlam
	check(slam ~= nil and #slam.Contacts == 1, "Ground Slam lands once")
	local heavy = byId.HardPunch
	check(heavy ~= nil and #heavy.Contacts == 1, "Hard Punch lands once")
	-- The reason Hard Punch is blockable at all. If a retune ever moves its contact
	-- earlier than Punch's first, the heavy becomes the faster move and Block stops
	-- having anything to react to.
	check(
		jab ~= nil and heavy ~= nil and heavy.Duration * heavy.Contacts[1] > jab.Duration * jab.Contacts[1],
		"Hard Punch is slower to land than a jab"
	)
	check(
		slam ~= nil and heavy ~= nil and slam.Duration * slam.Contacts[1] > heavy.Duration * heavy.Contacts[1],
		"Ground Slam is the slowest telegraph of the three"
	)

	-- Effects are timed against the same clip as the joints, so an effect scheduled
	-- past the end of the strike would simply never play and nothing would say so.
	for _, strike in strikes do
		for _, effect in strike.Vfx or ({} :: { StrikeVfx }) do
			check(
				effect.At >= 0 and effect.At <= 1,
				`{strike.Id} effect "{effect.Effect}" is timed inside its clip`
			)
			check(#effect.Effect > 0, `{strike.Id} names every effect it schedules`)
		end
	end

	-- The client mirrors these cooldowns to decline doomed requests. AbilityConfig is
	-- Roblox-free so it cannot read a Strike's Duration itself; this is the check that
	-- keeps the two numbers from drifting apart silently.
	--
	-- It only fires where an ability id and a strike id match, which is why the punch
	-- needs its own check below: no strike is called "Punch" any more, so this loop
	-- silently stopped covering the game's most-used move.
	for _, entry in AbilityConfig.List do
		local strike = byId[entry.Id]
		if strike ~= nil then
			check(entry.Cooldown >= strike.Duration, `{entry.Id}'s mirrored cooldown covers its animation`)
		end
	end

	-- The punch's mirrored cooldown, checked against the chain rather than against one
	-- clip. Deliberately *shorter* than a swing: the next click cuts the previous
	-- swing's recovery, which is what makes a chain feel like a chain instead of three
	-- separate punches. What it may not do is outrun the remote's rate limit, or drop
	-- below the point where a swing has not even reached its contact frame.
	local punchEntry = nil
	for _, entry in AbilityConfig.List do
		if entry.Id == "Punch" then
			punchEntry = entry
		end
	end
	check(punchEntry ~= nil, "AbilityConfig still declares the punch")
	if punchEntry ~= nil and jab ~= nil then
		check(
			punchEntry.Cooldown > jab.Duration * jab.Contacts[1],
			"a punch cannot be re-thrown before the last one has landed"
		)
		check(punchEntry.Cooldown < jab.Duration, "chained swings cut into the previous recovery")
		-- AbilityActivate is rate-limited to eight a second server-side.
		check(punchEntry.Cooldown >= 0.125, "the punch cooldown stays inside the remote's rate limit")
	end

	return failures
end

return StrikeConfig
