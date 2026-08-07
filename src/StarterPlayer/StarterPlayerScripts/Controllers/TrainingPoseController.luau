--!strict
--[[
	TrainingPoseController — plays the training animations.

	The server marks a training character with a pose id and a rep interval; this
	turns those two attributes into movement. Every client runs it for every
	character it can see, not just its own, which is why the state travels as
	replicated attributes instead of a remote to one owner — a gym full of people
	lifting is most of what makes the room feel alive.

	Poses are generated from the numbers in PoseConfig rather than played from an
	uploaded animation, so the game owns everything it animates. See that module for
	why, and for what the angles mean.

	Three details make it work alongside Roblox's own animations:

	  * It writes the joint's Transform, the same field the animator writes. Posed
	    joints are overridden; every other joint keeps playing idle underneath, so a
	    benching character still breathes.
	  * A joint is a Motor6D on a classic rig and an AnimationConstraint on a rig
	    built since Roblox's avatar joint upgrade. Both expose Transform and mean the
	    same thing by it, so both are accepted — a rig with neither simply is not
	    posed. Do not assume Motor6D: current Studio builds ship characters with no
	    Motor6D in them at all.
	  * It runs on PreSimulation, which is after the animator has evaluated for the
	    frame and before the world step that turns joint transforms into part
	    positions. That window is the whole trick. Writing later — on Heartbeat, or
	    after RenderPriority.Character — sets the property but the value is
	    overwritten before anything reads it, and the body never moves.

	This controller knows nothing about any particular machine or pose. A new
	exercise is a PoseConfig entry, and nothing here changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

-- Seconds spent easing from wherever the body was into the pose, so mounting a
-- machine does not snap.
local BLEND_SECONDS = 0.3

-- Bound once: the blend-in lerps out of this, and clearing a joint restores it.
local IDENTITY: CFrame = CFrame.identity

--[[
	A rig joint, described by the one thing this controller needs from it.

	Motor6D (classic rigs) and AnimationConstraint (rigs built since Roblox's avatar
	joint upgrade) both carry a Transform layered over the joint's rest pose, and
	both mean the same thing by it — but they share no ancestor that declares it.
	Naming the shape instead of the classes is what lets one code path drive either
	without branching on rig generation everywhere.
]]
type Joint = Instance & { Transform: CFrame }

type Bound = {
	motion: PoseConfig.JointMotion,
	joint: Joint,
}

type Entry = {
	pose: PoseConfig.Pose,
	interval: number,
	joints: { Bound },
	startedAt: number,
}

local TrainingPoseController = {
	Name = "TrainingPoseController",
	Priority = 5,
}

local active: { [Model]: Entry } = {}

--[[
	Finds the joint a motion drives, translating R15 joint names to their R6
	equivalents on an R6 rig. Joints with no equivalent return nil and are dropped,
	which is how a pose degrades on R6 rather than erroring.

	Matched on name *and* class rather than name alone: a rig carries several
	instances per joint — RightShoulderAttachment, RightShoulderBallSocket — and a
	plain name search can land on one of those instead.
]]
local function findJoint(character: Model, rigType: Enum.HumanoidRigType, jointName: string): Joint?
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
	Stops posing a character and hands its joints back.

	Clearing Transform matters for joints no animation happens to be driving: the
	animator overwrites the ones it owns on the next frame regardless, but anything
	it does not touch would otherwise stay frozen in the last pose.
]]
function TrainingPoseController:_clear(character: Model)
	local entry = active[character]
	if entry == nil then
		return
	end

	active[character] = nil

	for _, bound in entry.joints do
		if bound.joint.Parent ~= nil then
			bound.joint.Transform = IDENTITY
		end
	end
end

--[[
	Reads a character's pose attributes and starts, restarts, or stops posing it.
]]
function TrainingPoseController:_sync(character: Model)
	local poseId = character:GetAttribute(PoseConfig.POSE_ATTRIBUTE)
	if type(poseId) ~= "string" then
		self:_clear(character)
		return
	end

	local pose = PoseConfig.Get(poseId)
	if pose == nil then
		warn(`[TrainingPoseController] {character.Name} asked for unknown pose "{poseId}"`)
		self:_clear(character)
		return
	end

	local existing = active[character]
	if existing ~= nil and existing.pose.Id == pose.Id then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local interval = character:GetAttribute(PoseConfig.INTERVAL_ATTRIBUTE)
	if type(interval) ~= "number" or interval <= 0 then
		interval = 1
	end

	self:_clear(character)

	local joints: { Bound } = {}
	for _, motion in pose.Joints do
		local joint = findJoint(character, humanoid.RigType, motion.Joint)
		if joint ~= nil then
			table.insert(joints, { motion = motion, joint = joint })
		end
	end

	active[character] = {
		pose = pose,
		interval = interval :: number,
		joints = joints,
		startedAt = os.clock(),
	}
end

local function poseAt(motion: PoseConfig.JointMotion, alpha: number): CFrame
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

function TrainingPoseController:_apply()
	local now = os.clock()

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local elapsed = now - entry.startedAt
		local blend = math.min(1, elapsed / BLEND_SECONDS)

		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end

			local phase = (elapsed / entry.interval * entry.pose.Cycles + (bound.motion.Phase or 0)) % 1
			-- Cosine rather than a sawtooth: a rep should ease into the top of the
			-- lift and back down, not tick between two poses.
			local alpha = 0.5 - 0.5 * math.cos(phase * math.pi * 2)

			bound.joint.Transform = IDENTITY:Lerp(poseAt(bound.motion, alpha), blend)
		end
	end
end

function TrainingPoseController:_watch(character: Model)
	self:_sync(character)

	character:GetAttributeChangedSignal(PoseConfig.POSE_ATTRIBUTE):Connect(function()
		self:_sync(character)
	end)

	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			self:_clear(character)
		end
	end)
end

function TrainingPoseController:_track(player: Player)
	if player.Character ~= nil then
		self:_watch(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		self:_watch(character)
	end)
end

function TrainingPoseController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	RunService.PreSimulation:Connect(function()
		self:_apply()
	end)
end

return TrainingPoseController
