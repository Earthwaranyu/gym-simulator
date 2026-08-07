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
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

-- Seconds spent easing from wherever the body was into the pose, so mounting a
-- machine does not snap.
local BLEND_SECONDS = 0.3

-- Bound once: the blend-in lerps out of this, and clearing a joint restores it.
local IDENTITY: CFrame = CFrame.identity

-- How a single-handed weight sits relative to the hand holding it. A dumbbell is
-- authored with its handle along its own X, and a hand's X runs across the palm,
-- so the two already agree; this only lifts it into the grip.
local GRIP_OFFSET = CFrame.new(0, -0.35, 0)

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

--[[
	A weight that follows the lifter's hands, and where it belongs when they let go.

	Props are moved on the client only. Nothing about them is replicated: every client
	independently puts the same weight in the same hands, and a client that never sees
	the lifter leaves it racked. That also means `rest` is read straight off the
	instance the first time it is bound, when it is guaranteed to still be at rest,
	and remembered from then on.
]]
type HeldProp = {
	prop: PVInstance,
	hand: string,
	rest: CFrame,
}

type Entry = {
	pose: PoseConfig.Pose,
	interval: number,
	joints: { Bound },
	props: { HeldProp },
	startedAt: number,
}

local TrainingPoseController = {
	Name = "TrainingPoseController",
	Priority = 5,
}

local active: { [Model]: Entry } = {}

-- Where every prop ever bound sits when nobody is holding it. Kept globally and
-- written once, so a prop always has somewhere honest to go back to even if the
-- lifter holding it disconnects mid-rep.
local restCFrames: { [PVInstance]: CFrame? } = {}

--[[
	The part a hand's weight should follow, on either rig generation.
]]
local function findHand(character: Model, hand: string): BasePart?
	local part = character:FindFirstChild(`{hand}Hand`) or character:FindFirstChild(`{hand} Arm`)
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

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
	Collects the weights parked beside the anchor a character is training on.

	The anchor arrives as an ObjectValue the server puts in the character; the props
	are its siblings, so a machine declares them purely by where it puts them in the
	model. A machine with none — a treadmill, an ab bench — yields an empty list and
	costs nothing further.
]]
local function collectProps(character: Model): { HeldProp }
	local props: { HeldProp } = {}

	local anchorValue = character:FindFirstChild(EquipmentConfig.ANCHOR_VALUE_NAME)
	if anchorValue == nil or not anchorValue:IsA("ObjectValue") then
		return props
	end

	local anchor = anchorValue.Value
	if anchor == nil or anchor.Parent == nil then
		return props
	end

	for hand, name in EquipmentConfig.HELD_NAMES do
		local found = anchor.Parent:FindFirstChild(name)
		if found ~= nil and found:IsA("PVInstance") then
			local remembered = restCFrames[found]
			local rest: CFrame = if remembered ~= nil then remembered else found:GetPivot()
			restCFrames[found] = rest
			table.insert(props, { prop = found, hand = hand, rest = rest })
		end
	end

	return props
end

--[[
	Puts every weight back where the machine keeps it.
]]
local function releaseProps(entry: Entry)
	for _, held in entry.props do
		if held.prop.Parent ~= nil then
			held.prop:PivotTo(held.rest)
		end
	end
	table.clear(entry.props)
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
	releaseProps(entry)

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
		props = collectProps(character),
		startedAt = os.clock(),
	}
end

--[[
	Re-reads which weights a character is holding.

	Separate from _sync because the anchor ObjectValue and the pose attribute are two
	instances replicating independently: whichever lands second has to be able to
	complete the picture on its own.
]]
function TrainingPoseController:_syncProps(character: Model)
	local entry = active[character]
	if entry == nil then
		return
	end
	releaseProps(entry)
	entry.props = collectProps(character)
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

		self:_carry(character, entry)
	end
end

--[[
	Moves a lifter's weights into their hands for this frame.

	Reads hand positions rather than recomputing them from the pose, so a weight
	follows whatever the body is actually doing — including the idle animation
	underneath, and the blend on the way in. The hands are a frame behind the joint
	writes just made, which at 60fps nobody can see.
]]
function TrainingPoseController:_carry(character: Model, entry: Entry)
	for _, held in entry.props do
		if held.prop.Parent == nil then
			continue
		end

		if held.hand == "Both" then
			-- A barbell spans the grip: centred between the hands and lying along the
			-- line joining them, so the plates stay upright however the arms move.
			local right = findHand(character, "Right")
			local left = findHand(character, "Left")
			if right == nil or left == nil then
				continue
			end

			local span = right.Position - left.Position
			if span.Magnitude < 0.1 then
				continue
			end

			local axis = span.Unit
			local back = axis:Cross(Vector3.yAxis)
			if back.Magnitude < 0.01 then
				continue
			end
			back = back.Unit

			held.prop:PivotTo(
				CFrame.fromMatrix((right.Position + left.Position) / 2, axis, back:Cross(axis).Unit, back)
			)
		else
			local hand = findHand(character, held.hand)
			if hand ~= nil then
				held.prop:PivotTo(hand.CFrame * GRIP_OFFSET)
			end
		end
	end
end

function TrainingPoseController:_watch(character: Model)
	self:_sync(character)

	character:GetAttributeChangedSignal(PoseConfig.POSE_ATTRIBUTE):Connect(function()
		self:_sync(character)
	end)

	-- The anchor reference and the pose attribute replicate independently, so the
	-- weights are rebound whenever the reference itself appears or disappears.
	local function onAnchorValue(child: Instance)
		if child.Name == EquipmentConfig.ANCHOR_VALUE_NAME then
			self:_syncProps(character)
		end
	end
	character.ChildAdded:Connect(onAnchorValue)
	character.ChildRemoved:Connect(onAnchorValue)

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
