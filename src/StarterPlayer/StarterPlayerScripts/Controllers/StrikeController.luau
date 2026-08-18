--!strict
--[[
	StrikeController — plays the punch, on everybody you can see.

	The sibling of TrainingPoseController, and deliberately built the same way: the
	server stamps an attribute on the attacker's character, every client notices and
	animates it locally. Nothing about the animation is replicated, because it does
	not need to be — the numbers are in StrikeConfig and every machine already has
	them, so all that has to cross the wire is "he swung, at this moment".

	Where a training pose loops until the attributes go away, a strike runs once. It
	holds the joints for its duration, then hands them straight back — including to
	TrainingPoseController if the attacker happened to be on a machine, which is why
	the joints are cleared rather than eased to zero: whoever owns them next writes
	over the top on their own next frame.

	Runs on PreSimulation for the same reason the pose controller does. That is the
	window after the animator has evaluated and before the world step reads the joint
	transforms; write later and the property is set but nothing ever sees it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)

local StrikeController = {
	Name = "StrikeController",
	Priority = 6,
}

local IDENTITY: CFrame = CFrame.identity

-- How long a strike takes to blend out of whatever the body was already doing.
--
-- This was not needed while a punch was one input: a strike only ever started from a
-- body at rest, so beginning at the clip's own first pose was beginning where the body
-- already was. Chained swings interrupt each other mid-recovery, and a click landing on
-- the contact frame would otherwise snap a fully extended arm from 102 degrees to zero
-- in a single frame.
local BLEND_SECONDS = 0.07

type Playing = {
	strike: StrikeConfig.Strike,
	startedAt: number,
	-- Resolved once per swing rather than per frame: a rig is a few hundred instances
	-- and a punch is thrown several times a second in a fight.
	joints: { { [string]: any } },
}

local active: { [Model]: Playing } = {}

--[[
	Which stage of the strike we are in, and how far through it.

	Stages are given as fractions of the whole so the clip can be retimed by changing
	one Duration, rather than by editing every boundary.
]]
local function stageAt(strike: StrikeConfig.Strike, progress: number): (StrikeConfig.StrikeStage?, number)
	local start = 0
	for _, stage in strike.Stages do
		local finish = start + stage.Portion
		if progress < finish or finish >= 1 then
			local span = math.max(1e-4, stage.Portion)
			return stage, math.clamp((progress - start) / span, 0, 1)
		end
		start = finish
	end
	return nil, 0
end

local function ease(stage: StrikeConfig.StrikeStage, alpha: number): number
	if stage.Easing == "Snap" then
		-- Explosive ease-out: most of the extension happens immediately after release.
		return 1 - (1 - alpha) ^ 4
	elseif stage.Easing == "Recover" then
		-- Smoothstep avoids a visible velocity corner as the arm returns to locomotion.
		return alpha * alpha * (3 - 2 * alpha)
	end
	-- Coil settles into the loaded silhouette without drifting linearly.
	return 1 - math.cos(alpha * math.pi * 0.5)
end

function StrikeController:_clear(character: Model)
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
	Starts a strike on a character, replacing any swing already in flight.
]]
function StrikeController:_begin(character: Model, strikeId: string)
	local strike = StrikeConfig.Get(strikeId)
	if strike == nil then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	-- Deliberately not _clear'd first. Clearing sets every joint to identity, and the
	-- pose captured below would then be identity for all of them — which is exactly the
	-- snap this blend exists to remove.
	active[character] = nil

	-- Every joint the strike touches at any stage, resolved once. A joint that this
	-- rig does not have — an R6 elbow — is dropped here rather than checked per frame.
	--
	-- Each one's current Transform is captured with it, so a swing that interrupts
	-- another starts from wherever the arm actually is rather than from neutral.
	local joints: { { [string]: any } } = {}
	local seen: { [string]: boolean } = {}
	for _, stage in strike.Stages do
		for _, motion in stage.Joints do
			if not seen[motion.Joint] then
				seen[motion.Joint] = true
				local joint = PosePlayback.FindJoint(character, humanoid.RigType, motion.Joint)
				if joint ~= nil then
					table.insert(joints, { name = motion.Joint, joint = joint, from = joint.Transform })
				end
			end
		end
	end

	active[character] = {
		strike = strike,
		startedAt = os.clock(),
		joints = joints,
	}
end

function StrikeController:_apply()
	local now = os.clock()

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local progress = (now - entry.startedAt) / entry.strike.Duration
		if progress >= 1 then
			self:_clear(character)
			continue
		end

		local blend = math.min(1, (now - entry.startedAt) / BLEND_SECONDS)
		local stage, alpha = stageAt(entry.strike, progress)
		if stage == nil then
			self:_clear(character)
			continue
		end
		alpha = ease(stage, alpha)

		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end
			-- A joint this stage does not mention keeps whatever the last stage left
			-- it at, which is what makes the three stages read as one movement.
			for _, motion in stage.Joints do
				if motion.Joint == bound.name then
					local posed = PosePlayback.PoseAt(motion, alpha)
					-- Eased in from where the joint was when the swing began. Only the
					-- first few frames of a strike are affected; after that `blend` is
					-- one and this is exactly what it always was.
					if blend < 1 then
						posed = (bound.from :: CFrame):Lerp(posed, blend)
					end
					bound.joint.Transform = posed
					break
				end
			end
		end
	end
end

--[[
	Watches one character for the server's swing stamp.
]]
function StrikeController:_watch(character: Model)
	character:GetAttributeChangedSignal(StrikeConfig.STRIKE_ATTRIBUTE):Connect(function()
		local at = character:GetAttribute(StrikeConfig.STRIKE_ATTRIBUTE)
		if type(at) ~= "number" then
			return
		end
		local id = character:GetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE)
		self:_begin(character, if type(id) == "string" then id else "Punch")
	end)
end

function StrikeController:_track(player: Player)
	if player.Character ~= nil then
		self:_watch(player.Character)
	end
	player.CharacterAdded:Connect(function(model: Model)
		self:_watch(model)
	end)
	player.CharacterRemoving:Connect(function(model: Model)
		self:_clear(model)
	end)
end

function StrikeController:Start()
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

return StrikeController
