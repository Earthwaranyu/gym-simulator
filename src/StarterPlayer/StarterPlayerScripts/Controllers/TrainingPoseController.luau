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

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)
local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local WeightConfig = require(ReplicatedStorage.Modules.WeightConfig)

-- Seconds spent easing from wherever the body was into the pose, so mounting a
-- machine does not snap.
local BLEND_SECONDS = 0.3

-- Bound once: the blend-in lerps out of this, and clearing a joint restores it.
local IDENTITY: CFrame = CFrame.identity

--[[
	Secondary motion: the small, constant, non-authored movement that separates a
	body holding a weight from a mannequin posed with one. Amplitudes are in
	radians and deliberately tiny -- under a degree -- because this reads as life
	only while it stays below the threshold where it reads as a second animation.

	The weights are per joint: the waist carries the most, the neck follows it,
	and the root moves least because moving the root moves everything above it.
]]
local SECONDARY_WEIGHT: { [string]: number } = {
	Waist = 1.0,
	UpperTorso = 1.0,
	Neck = 0.7,
	Root = 0.35,
}

-- Breathing is the fast component; the two sways are slow and mutually prime so
-- the three never line up into an obvious loop.
local BREATH_RATE = 1.9
local BREATH_AMPLITUDE = 0.012
local SWAY_AMPLITUDE = 0.010
local ROLL_AMPLITUDE = 0.008

-- Seconds of a set after which the drift is at full strength. A lifter looks
-- steadier on the first rep than the twentieth, and nothing about the pose itself
-- can express that: every rep it plays is identical to the last.
local FATIGUE_RAMP = 45

-- How a single-handed weight sits relative to the hand holding it. A dumbbell is
-- authored with its handle along its own X, and a hand's X runs across the palm,
-- so the two already agree; this only lifts it into the grip.
local GRIP_OFFSET = CFrame.new(0, -0.35, 0)

-- Motor6D or AnimationConstraint, whichever this rig generation carries.
-- PosePlayback owns that distinction and the code that resolves it.
type Joint = PosePlayback.Joint

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
	gripStyle: string?,
}

type Entry = {
	pose: PoseConfig.Pose,
	interval: number,
	joints: { Bound },
	props: { HeldProp },
	spot: Instance?,
	startedAt: number,
	-- Fixed per character, so the secondary layer differs between lifters.
	seed: number,
}

local TrainingPoseController = {
	Name = "TrainingPoseController",
	Priority = 5,
}

local TrainingController: any = nil

local active: { [Model]: Entry } = {}

--[[
	Joints still easing back to rest after a dismount.

	Clearing used to write identity in a single frame, which snaps a lifter out of
	a deep squat into a stand. The blend-in has always been eased; this is the same
	courtesy on the way out. Gait is suppressed for the fraction of a second it
	takes, because this controller writes after it -- a far better trade than the
	visible pop it replaces.
]]
type Releasing = {
	joints: { { joint: Joint, from: CFrame } },
	startedAt: number,
}

local releasing: { [Model]: Releasing } = {}

--[[
	A stable per-character number, so two lifters on adjacent machines are not
	breathing in lockstep. Derived from the name rather than randomised, so the
	same character drifts the same way on every client watching it.
]]
local function seedFor(character: Model): number
	local seed = 0
	for index = 1, #character.Name do
		seed = (seed * 31 + string.byte(character.Name, index)) % 9973
	end
	return seed / 9973 * math.pi * 2
end

--[[
	The additive layer, as a rotation to post-multiply onto the authored pose.

	Post-multiplied rather than blended in, so it perturbs the pose the author
	wrote instead of pulling it toward something else: the lockout is still the
	lockout, it just is not frozen.
]]
local function secondaryRotation(jointName: string, elapsed: number, seed: number, fatigue: number): CFrame?
	local weight = SECONDARY_WEIGHT[jointName]
	if weight == nil then
		return nil
	end

	-- Breathing is steady; the sways grow as the set wears on.
	local drift = 0.5 + fatigue
	local breath = math.sin(elapsed * BREATH_RATE + seed) * BREATH_AMPLITUDE * weight
	local sway = math.sin(elapsed * 0.7 + seed * 1.7) * SWAY_AMPLITUDE * weight * drift
	local roll = math.cos(elapsed * 0.53 + seed * 2.3) * ROLL_AMPLITUDE * weight * drift
	return CFrame.Angles(breath + sway, 0, roll)
end
-- Retained independently of the replicated anchor ObjectValue. Roblox may remove
-- that reference before the pose attribute on dismount; the cached pieces still
-- have to return to their authored resting wave in either replication order.
local battleRopes: { [Model]: { BasePart } } = {}
local stackParts: { [Model]: { BasePart } } = {}

-- Where every prop ever bound sits when nobody is holding it. Kept globally and
-- written once, so a prop always has somewhere honest to go back to even if the
-- lifter holding it disconnects mid-rep.
local restCFrames: { [PVInstance]: CFrame? } = {}

type LoadOriginal = {
	transparency: number,
	size: Vector3,
	cframe: CFrame,
}

-- Client-only visual state. The server sends kg and a normalized ratio on the
-- character; each viewer independently reveals the same physical plates.
local loadOriginals: { [BasePart]: LoadOriginal } = {}

local function loadOriginal(part: BasePart): LoadOriginal
	local original = loadOriginals[part]
	if original == nil then
		original = { transparency = part.Transparency, size = part.Size, cframe = part.CFrame }
		loadOriginals[part] = original
	end
	return original
end

local function activeSpotFromCharacter(character: Model): Instance?
	local anchorValue = character:FindFirstChild(EquipmentConfig.ANCHOR_VALUE_NAME)
	if anchorValue == nil or not anchorValue:IsA("ObjectValue") or anchorValue.Value == nil then
		return nil
	end
	local current: Instance? = anchorValue.Value
	while current ~= nil and current.Parent ~= nil do
		if CollectionService:HasTag(current.Parent, EquipmentConfig.STATION_TAG) then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function applyIndexedVisuals(root: Instance, visualKind: string, ratio: number)
	for _, descendant in root:GetDescendants() do
		if not descendant:IsA("BasePart") then
			continue
		end
		if descendant:GetAttribute(WeightConfig.VISUAL_KIND_ATTRIBUTE) ~= visualKind then
			continue
		end

		local original = loadOriginal(descendant)
		if visualKind == "DumbbellHead" then
			-- Zero means a genuinely bare iron handle. Older authored dumbbells use one
			-- scalable head per side; reveal those only after the player adds load.
			local thickness = 0.82 + ratio * 0.38
			local diameter = 0.74 + ratio * 0.56
			descendant.Size = Vector3.new(
				original.size.X * thickness,
				original.size.Y * diameter,
				original.size.Z * diameter
			)
			descendant.Transparency = if ratio <= 0.001 then 1 else original.transparency
			continue
		end

		local index = descendant:GetAttribute(WeightConfig.VISUAL_INDEX_ATTRIBUTE)
		local count = descendant:GetAttribute(WeightConfig.VISUAL_COUNT_ATTRIBUTE)
		if type(index) ~= "number" or type(count) ~= "number" or count <= 0 then
			continue
		end
		-- Free weights and body-carried Olympic discs store a complete configuration
		-- per load and swap between them. Only machine stacks are cumulative slices.
		local visibleCount = math.floor(math.clamp(ratio, 0, 1) * count + 0.5)
		local stateVisual = visualKind == WeightConfig.FREE_PLATE_KIND
			or visualKind == WeightConfig.BODY_PLATE_KIND
		local visible = if stateVisual then index == visibleCount else index <= visibleCount
		descendant.Transparency = if visible then 0 else 1
	end
end

local function applyLoadVisuals(character: Model, entry: Entry)
	local ratioValue = character:GetAttribute(WeightConfig.CHARACTER_RATIO_ATTRIBUTE)
	local ratio = if type(ratioValue) == "number" then math.clamp(ratioValue, 0, 1) else 0

	for _, held in entry.props do
		if held.prop.Parent ~= nil then
			applyIndexedVisuals(held.prop, WeightConfig.FREE_PLATE_KIND, ratio)
			applyIndexedVisuals(held.prop, WeightConfig.BODY_PLATE_KIND, ratio)
			applyIndexedVisuals(held.prop, "DumbbellHead", ratio)
		end
	end

	-- Machine stacks are deliberately absent from this pass. A selectorised tower
	-- always holds all ten plates no matter what you set it to — the load is the pin's
	-- position, not how many plates exist — so hiding the unselected ones left a light
	-- load looking like a tower somebody had emptied. They stay visible; animateStack
	-- carries the meaning by lifting the block above the pin.
end

-- A selectorized cable machine does not merely light up stack slices: every visible
-- selected plate rises and returns once per repetition. Movement is deliberately
-- modest so it reads as a guided weight stack rather than clipping through its tower.
local function animateStack(character: Model, pose: PoseConfig.Pose, elapsed: number, interval: number)
	local parts = stackParts[character]
	if parts == nil then
		local spot = activeSpotFromCharacter(character)
		if spot == nil then
			return
		end
		parts = {}
		for _, descendant in spot:GetDescendants() do
			if not descendant:IsA("BasePart") then
				continue
			end
			local kind = descendant:GetAttribute(WeightConfig.VISUAL_KIND_ATTRIBUTE)
			if kind == WeightConfig.STACK_PLATE_KIND or kind == WeightConfig.STACK_PIN_KIND then
				table.insert(parts, descendant)
			end
		end
		stackParts[character] = parts
	end
	local ratioValue = character:GetAttribute(WeightConfig.CHARACTER_RATIO_ATTRIBUTE)
	local ratio = if type(ratioValue) == "number" then math.clamp(ratioValue, 0, 1) else 0
	-- Follow the same curve as the avatar. This keeps the physical stack, held
	-- handles, stat popup and visible rep on one clock—including controlled pauses.
	local leadMotion = pose.Joints[1]
	local liftAlpha = if leadMotion ~= nil
		then PosePlayback.AlphaAt(pose, leadMotion, elapsed, interval)
		else 0
	local lift = liftAlpha * 0.48

	for _, descendant in parts do
		if descendant.Parent == nil then
			continue
		end
		local index = descendant:GetAttribute(WeightConfig.VISUAL_INDEX_ATTRIBUTE)
		local count = descendant:GetAttribute(WeightConfig.VISUAL_COUNT_ATTRIBUTE)
		if type(index) ~= "number" or type(count) ~= "number" then
			continue
		end
		local original = loadOriginal(descendant)
		-- How many plates the pin has picked up. Index 1 is the bottom of the tower, so
		-- the selected block is the *top* `selected` plates: a pin goes in at the chosen
		-- plate and everything above it comes up with the cable. Lifting the bottom ones
		-- instead — which is what this did — leaves the rest of the stack hanging in
		-- mid-air above a gap, which is the single thing that made it look fake.
		local selected = math.clamp(math.floor(ratio * count + 0.5), 0, count)
		local firstLifted = count - selected + 1

		if descendant:GetAttribute(WeightConfig.VISUAL_KIND_ATTRIBUTE) == WeightConfig.STACK_PIN_KIND then
			-- The pin sits at the lowest plate that travels, and stays home when the
			-- selection is empty rather than parking itself off the bottom of the tower.
			local plateSpacing = original.size.Y
			local seat = if selected <= 0 then 0 else (firstLifted - 1) * (plateSpacing / math.max(count, 1))
			descendant.CFrame = original.cframe * CFrame.new(0, seat + (if selected > 0 then lift else 0), 0)
			continue
		end

		descendant.CFrame = original.cframe
			* CFrame.new(0, if index >= firstLifted and selected > 0 then lift else 0, 0)
	end
end

local function resetStack(character: Model)
	local parts = stackParts[character]
	if parts == nil then
		return
	end
	for _, descendant in parts do
		if descendant.Parent ~= nil then
			local original = loadOriginals[descendant]
			if original ~= nil then
				descendant.CFrame = original.cframe
			end
		end
	end
	stackParts[character] = nil
end

--[[
	The part a hand's weight should follow, on either rig generation.
]]
local function findHand(character: Model, hand: string): BasePart?
	local part = character:FindFirstChild(`{hand}Hand`) or character:FindFirstChild(`{hand} Arm`)
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

local function findBodyPart(character: Model, r15Name: string, r6Name: string): BasePart?
	local part = character:FindFirstChild(r15Name) or character:FindFirstChild(r6Name)
	return if part ~= nil and part:IsA("BasePart") then part else nil
end

local function setRopeSegment(part: BasePart, from: Vector3, to: Vector3)
	local span = to - from
	local length = span.Magnitude
	if length < 0.01 then
		return
	end
	local up = span.Unit
	local seed = if math.abs(up:Dot(Vector3.xAxis)) < 0.9 then Vector3.xAxis else Vector3.zAxis
	local right = seed:Cross(up).Unit
	local back = right:Cross(up).Unit
	part.Size = Vector3.new(part.Size.X, length, part.Size.Z)
	part.CFrame = CFrame.fromMatrix((from + to) / 2, right, up, back)
end

--[[
	Battle ropes are short authored pieces. The first end remains bolted to the
	station and the final end follows its hand; a travelling wave between them makes
	the exercise read instead of leaving two rigid bars stuck through the avatar.
]]
local function animateBattleRopes(character: Model, elapsed: number)
	local cached = battleRopes[character]
	if cached == nil then
		local spot = activeSpotFromCharacter(character)
		if spot == nil then
			return
		end
		cached = {}
		for _, descendant in spot:GetDescendants() do
			if descendant:IsA("BasePart") and descendant:GetAttribute("BattleRopeSide") ~= nil then
				table.insert(cached, descendant)
			end
		end
		battleRopes[character] = cached
	end

	for _, side in { "Right", "Left" } do
		local segments: { BasePart } = {}
		for _, segment in cached do
			if segment.Parent ~= nil and segment:GetAttribute("BattleRopeSide") == side then
				table.insert(segments, segment)
			end
		end
		table.sort(segments, function(a: BasePart, b: BasePart): boolean
			local aIndex = a:GetAttribute("BattleRopeIndex")
			local bIndex = b:GetAttribute("BattleRopeIndex")
			return (if type(aIndex) == "number" then aIndex else 0)
				< (if type(bIndex) == "number" then bIndex else 0)
		end)
		if #segments < 2 then
			continue
		end

		local hand = findHand(character, side)
		if hand == nil then
			continue
		end
		local first = loadOriginal(segments[1]).cframe.Position
		local second = loadOriginal(segments[2]).cframe.Position
		local fixed = first - (second - first) / 2
		local handPosition = hand.Position + Vector3.new(0, -0.35, 0)
		local previous = fixed
		for index, segment in segments do
			local alpha = index / #segments
			local point = fixed:Lerp(handPosition, alpha)
			local envelope = math.sin(alpha * math.pi)
			local phase = elapsed * 10 - alpha * math.pi * 3
			point += Vector3.new(0, math.sin(phase) * 0.5 * envelope, 0)
			setRopeSegment(segment, previous, point)
			previous = point
		end
	end
end

local function resetBattleRopes(character: Model)
	local cached = battleRopes[character]
	if cached == nil then
		return
	end
	for _, part in cached do
		if part.Parent ~= nil then
			local original = loadOriginals[part]
			if original ~= nil then
				part.Size = original.size
				part.CFrame = original.cframe
			end
		end
	end
	battleRopes[character] = nil
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
			local gripStyle = found:GetAttribute("GripStyle")
			table.insert(props, {
				prop = found,
				hand = hand,
				rest = rest,
				gripStyle = if type(gripStyle) == "string" then gripStyle else nil,
			})
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

	-- The pose attribute can replicate away before the load ratio and anchor value.
	-- Restore an honestly unloaded machine explicitly instead of depending on those
	-- later signals: free plates hide, dumbbell heads return to bare size, and every
	-- stack slice parks and hides even if its ObjectValue reference has already gone.
	for _, held in entry.props do
		if held.prop.Parent ~= nil then
			applyIndexedVisuals(held.prop, WeightConfig.FREE_PLATE_KIND, 0)
			applyIndexedVisuals(held.prop, WeightConfig.BODY_PLATE_KIND, 0)
			applyIndexedVisuals(held.prop, "DumbbellHead", 0)
		end
	end
	if entry.spot ~= nil and entry.spot.Parent ~= nil then
		applyIndexedVisuals(entry.spot, WeightConfig.STACK_PLATE_KIND, 0)
	end
	resetStack(character)
	resetBattleRopes(character)
	active[character] = nil
	releaseProps(entry)

	local easing: { { joint: Joint, from: CFrame } } = {}
	for _, bound in entry.joints do
		if bound.joint.Parent ~= nil then
			table.insert(easing, { joint = bound.joint, from = bound.joint.Transform })
		end
	end
	if #easing > 0 then
		releasing[character] = { joints = easing, startedAt = os.clock() }
	end
end

--[=[
	Stops the local player's procedural pose without changing the authoritative
	training session. This is used for immediate input feedback; the server performs
	the actual dismount, exit teleport and unanchor a moment later.

	Changing the local Humanoid state is important for lying and hanging exercises.
	Those poses can leave Roblox's character controller in a non-running state even
	after their joint transforms are cleared, which looked like a one-second freeze.
]=]
function TrainingPoseController:_releaseLocalPlayer()
	local character = Players.LocalPlayer.Character
	if character == nil then
		return
	end
	self:_clear(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.Health > 0 then
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
	end

	-- An invalid or rate-limited request must not leave an unposed avatar permanently
	-- anchored to an active machine. If the server still says this same session exists
	-- after a generous round trip, resume from the replicated pose attributes.
	task.delay(0.75, function()
		if
			character.Parent ~= nil
			and active[character] == nil
			and type(character:GetAttribute(PoseConfig.POSE_ATTRIBUTE)) == "string"
			and TrainingController:IsTraining()
		then
			self:_sync(character)
		end
	end)
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

	-- One walk of the rig for the whole pose, rather than one per joint.
	local index = PosePlayback.BuildJointIndex(character)
	local joints: { Bound } = {}
	for _, motion in pose.Joints do
		local joint = PosePlayback.FindJoint(character, humanoid.RigType, motion.Joint, index)
		if joint ~= nil then
			table.insert(joints, { motion = motion, joint = joint })
		end
	end

	-- Remounting cancels any half-finished ease-out: these joints are being driven
	-- again, and two writers on one joint is exactly the fight this avoids.
	releasing[character] = nil

	active[character] = {
		pose = pose,
		interval = interval :: number,
		joints = joints,
		props = collectProps(character),
		spot = activeSpotFromCharacter(character),
		startedAt = os.clock(),
		seed = seedFor(character),
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
	entry.spot = activeSpotFromCharacter(character)
	entry.props = collectProps(character)
	applyLoadVisuals(character, entry)
end

function TrainingPoseController:_apply()
	local now = os.clock()

	for character, release in releasing do
		local blend = (now - release.startedAt) / BLEND_SECONDS
		local done = blend >= 1
		for _, bound in release.joints do
			if bound.joint.Parent ~= nil then
				bound.joint.Transform = if done then IDENTITY else bound.from:Lerp(IDENTITY, blend)
			end
		end
		if done then
			releasing[character] = nil
		end
	end

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local elapsed = now - entry.startedAt
		local blend = math.min(1, elapsed / BLEND_SECONDS)
		local fatigue = math.clamp(elapsed / FATIGUE_RAMP, 0, 1)

		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end

			local alpha = PosePlayback.AlphaAt(entry.pose, bound.motion, elapsed, entry.interval)
			local target = PosePlayback.PoseAt(bound.motion, alpha)

			local extra = secondaryRotation(bound.motion.Joint, elapsed, entry.seed, fatigue)
			if extra ~= nil then
				target *= extra
			end

			bound.joint.Transform = IDENTITY:Lerp(target, blend)
		end

		self:_carry(character, entry)
		if entry.pose.Id == "BattleRopes" then
			animateBattleRopes(character, elapsed)
		end
		animateStack(character, entry.pose, elapsed, entry.interval)
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

		if held.hand == "Waist" then
			local torso = findBodyPart(character, "LowerTorso", "Torso")
			if torso ~= nil then
				held.prop:PivotTo(torso.CFrame * CFrame.new(0, -1.45, 0.1))
			end
		elseif held.hand == "Back" then
			local torso = findBodyPart(character, "UpperTorso", "Torso")
			if torso ~= nil then
				held.prop:PivotTo(torso.CFrame * CFrame.new(0, 0.2, 0.72))
			end
		elseif held.hand == "Both" then
			-- A barbell spans the grip: centred between the hands and lying along the
			-- line joining them, so the plates stay upright however the arms move.
			local right = findHand(character, "Right")
			local left = findHand(character, "Left")
			if right == nil or left == nil then
				continue
			end
			local centre = (right.Position + left.Position) / 2
			if held.gripStyle == "ChestPlate" then
				local torso = findBodyPart(character, "UpperTorso", "Torso")
				if torso ~= nil then
					held.prop:PivotTo(
						CFrame.new(centre) * torso.CFrame.Rotation * CFrame.Angles(0, math.rad(90), 0)
					)
				end
				continue
			end

			local span = right.Position - left.Position
			if span.Magnitude < 0.1 then
				continue
			end

			local axis: Vector3
			if held.gripStyle == "LevelBar" then
				-- A loaded olympic bar does not roll. Taking the grip axis straight from
				-- the hands makes every asymmetry visible as bar tilt — mismatched hand
				-- heights from the idle animation underneath, from the blend-in, or from
				-- a pose whose two shoulders are not exactly mirrored — and a bar that
				-- rocks a few degrees each rep reads as the whole lift being wrong.
				-- Flattening the axis keeps the bar horizontal and leaves the hands to
				-- supply only its height and heading.
				local flat = Vector3.new(span.X, 0, span.Z)
				axis = if flat.Magnitude > 0.05 then flat.Unit else held.rest.RightVector
			else
				axis = span.Unit
			end

			local back = axis:Cross(Vector3.yAxis)
			if back.Magnitude < 0.01 then
				continue
			end
			back = back.Unit

			held.prop:PivotTo(CFrame.fromMatrix(centre, axis, back:Cross(axis).Unit, back))
		else
			local hand = findHand(character, held.hand)
			if hand ~= nil then
				local gripRotation = if held.gripStyle == "Neutral"
					then CFrame.Angles(0, math.rad(90), 0)
					else CFrame.identity
				held.prop:PivotTo(hand.CFrame * gripRotation * GRIP_OFFSET)
			end
		end
	end
end

function TrainingPoseController:_watch(character: Model)
	self:_sync(character)

	character:GetAttributeChangedSignal(PoseConfig.POSE_ATTRIBUTE):Connect(function()
		self:_sync(character)
	end)
	character:GetAttributeChangedSignal(WeightConfig.CHARACTER_RATIO_ATTRIBUTE):Connect(function()
		local entry = active[character]
		if entry ~= nil then
			applyLoadVisuals(character, entry)
		end
	end)
	character:GetAttributeChangedSignal(PoseConfig.INTERVAL_ATTRIBUTE):Connect(function()
		local entry = active[character]
		local value = character:GetAttribute(PoseConfig.INTERVAL_ATTRIBUTE)
		if entry ~= nil and type(value) == "number" and value > 0 then
			entry.interval = value
			-- Weight changes restart the server's rep clock. Restart the pose clock too,
			-- so the next popup still lands at the completion beat instead of mid-motion.
			entry.startedAt = os.clock()
		end
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

function TrainingPoseController:Init()
	TrainingController = Loader.Get("TrainingController")
end

function TrainingPoseController:Start()
	-- Space/jump can release immediately, before the StopTraining request reaches the
	-- server. TrainingChanged covers hold-E, travel and every server-originated exit.
	TrainingController.StopRequested:Connect(function()
		self:_releaseLocalPlayer()
	end)
	TrainingController.Changed:Connect(function(state: any)
		if type(state) == "table" and state.StationId == nil then
			self:_releaseLocalPlayer()
		end
	end)

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
