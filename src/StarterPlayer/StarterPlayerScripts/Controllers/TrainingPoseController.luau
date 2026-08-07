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

	Two details make it work alongside Roblox's own animations:

	  * It writes Motor6D.Transform, the same field the animator writes. Posed
	    joints are overridden; every other joint keeps playing idle underneath, so a
	    benching character still breathes.
	  * It runs at render priority just after Character, so it lands after the
	    animator has written for the frame. Earlier in the frame and the idle
	    animation would simply overwrite it.

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
-- Must sit after Enum.RenderPriority.Character, which is when the animator runs.
local RENDER_PRIORITY = Enum.RenderPriority.Character.Value + 1
local RENDER_NAME = "TrainingPose"

-- Bound once: the blend-in lerps out of this, and clearing a joint restores it.
local IDENTITY: CFrame = CFrame.identity

type Bound = {
	motion: PoseConfig.JointMotion,
	motor: Motor6D,
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
	Finds the Motor6D a motion drives, translating R15 joint names to their R6
	equivalents on an R6 rig. Joints with no equivalent return nil and are dropped,
	which is how a pose degrades on R6 rather than erroring.
]]
local function findMotor(character: Model, rigType: Enum.HumanoidRigType, jointName: string): Motor6D?
	local name = jointName
	if rigType == Enum.HumanoidRigType.R6 then
		local alias = PoseConfig.R6Joints[jointName]
		if alias == nil then
			return nil
		end
		name = alias
	end

	local found = character:FindFirstChild(name, true)
	if found ~= nil and found:IsA("Motor6D") then
		return found
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
		if bound.motor.Parent ~= nil then
			bound.motor.Transform = IDENTITY
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
		local motor = findMotor(character, humanoid.RigType, motion.Joint)
		if motor ~= nil then
			table.insert(joints, { motion = motion, motor = motor })
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

function TrainingPoseController:_render()
	local now = os.clock()

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local elapsed = now - entry.startedAt
		local blend = math.min(1, elapsed / BLEND_SECONDS)

		for _, bound in entry.joints do
			if bound.motor.Parent == nil then
				continue
			end

			local phase = (elapsed / entry.interval * entry.pose.Cycles + (bound.motion.Phase or 0)) % 1
			-- Cosine rather than a sawtooth: a rep should ease into the top of the
			-- lift and back down, not tick between two poses.
			local alpha = 0.5 - 0.5 * math.cos(phase * math.pi * 2)

			bound.motor.Transform = IDENTITY:Lerp(poseAt(bound.motion, alpha), blend)
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

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, function()
		self:_render()
	end)
end

return TrainingPoseController
