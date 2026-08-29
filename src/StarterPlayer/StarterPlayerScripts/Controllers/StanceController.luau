--!strict
--[[
	StanceController — the arms a body's own mass will not let it lower.

	GaitController already folds StanceConfig's abduction into its shoulders, so a
	walking character spreads. This covers the other half: standing still. It exists as
	a separate controller only because the gait deliberately does nothing at rest —
	there is no idle pose to hang the offset on, and there must not be one, because
	GaitConfig.RunSelfTest asserts every entry in GaitConfig.List has all thirteen
	joints, hip opposition at exactly 0.5 and a knee lagging its hip. A standing pose
	satisfies none of those, and admitting one would mean weakening four real
	invariants to make room for a thing that is not a gait.

	Nothing additive is needed to sit on top of Roblox's idle clip. PoseConfig's header
	is explicit that writing Motor6D.Transform overrides the stock animation *on that
	joint only*, so claiming two shoulders locks the arms out while the idle's
	breathing, head motion and sway keep playing underneath, untouched.

	## Priority 8

	The weakest slot in the stack, and chosen for it. The Loader sorts descending and
	first-connected runs first, so the last writer wins: training poses (5), strikes
	and flight (6), flinch (6.5) and the gait (7) all overwrite this. A player bolted
	to a machine holds the machine's pose, a punch looks like a punch, and a hit breaks
	the stance visibly — none of which needs a rule here.

	Write order is the belt, not the braces. GaitConfig.BodyIsClaimed does the same job
	directly, for the reason FlinchController's header records: controller write order
	is not reliable enough to encode a gameplay rule in.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local StanceConfig = require(ReplicatedStorage.Modules.StanceConfig)
local GaitConfig = require(ReplicatedStorage.Modules.GaitConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)

local StanceController = {
	Name = "StanceController",
	Priority = 8,
}

local IDENTITY: CFrame = CFrame.identity

-- The gait's own cull, matched rather than re-picked: past this a character is a few
-- pixels tall and the width of its stance is not among them.
local CULL_DISTANCE = 260

type Bound = { name: string, joint: any }
type Entry = {
	joints: { Bound },
	torsoScale: NumberValue?,
	-- Whether we currently hold these joints. Tracked so the release writes identity
	-- exactly once instead of every frame somebody else owns the body.
	holding: boolean,
}

local active: { [Model]: Entry } = {}
local mobs: { [Model]: boolean } = {}

local function bindShoulders(character: Model): { Bound }
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return {}
	end
	local bound: { Bound } = {}
	-- Only what StanceConfig claims. Binding the gait's thirteen joints here would
	-- make this a second locomotion system by accident.
	for name in StanceConfig.SIGN do
		local joint = PosePlayback.FindJoint(character, humanoid.RigType, name)
		if joint ~= nil then
			table.insert(bound, { name = name, joint = joint })
		end
	end
	return bound
end

function StanceController:_release(character: Model)
	local entry = active[character]
	if entry == nil or not entry.holding then
		return
	end
	entry.holding = false
	for _, bound in entry.joints do
		if bound.joint.Parent ~= nil then
			bound.joint.Transform = IDENTITY
		end
	end
end

function StanceController:_clear(character: Model)
	self:_release(character)
	active[character] = nil
end

local function torsoScaleOf(character: Model): NumberValue?
	local scales = character:FindFirstChild("MuscleScales")
	if scales == nil then
		return nil
	end
	local value = scales:FindFirstChild("UpperTorso")
	if value ~= nil and value:IsA("NumberValue") then
		return value
	end
	return nil
end

--[[
	Whether this character should be standing spread right now.

	The speed test is the important one: above the gait's own entry threshold,
	GaitController owns these shoulders and applies the same offset itself. Two writers
	on one joint is the failure this whole file is arranged to avoid, so the handover
	uses the identical constant rather than one of its own.
]]
local function shouldHold(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return false
	end
	if GaitConfig.BodyIsClaimed(character) then
		return false
	end
	if humanoid.Sit then
		return false
	end
	local velocity = root.AssemblyLinearVelocity
	if Vector3.new(velocity.X, 0, velocity.Z).Magnitude >= Formulas.MIN_GAIT_SPEED then
		return false
	end
	return true
end

function StanceController:_sync(character: Model)
	if active[character] ~= nil then
		return
	end
	local joints = bindShoulders(character)
	if #joints == 0 then
		return
	end
	active[character] = {
		joints = joints,
		torsoScale = torsoScaleOf(character),
		holding = false,
	}
end

function StanceController:_apply()
	local camera = workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else Vector3.zero

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			self:_clear(character)
			continue
		end
		if (root.Position - eye).Magnitude > CULL_DISTANCE or not shouldHold(character) then
			-- Hand the joints back rather than freezing them, so a character that
			-- streams back in is not holding a stale spread.
			self:_release(character)
			continue
		end

		local scale = entry.torsoScale
		local degrees = if scale ~= nil then StanceConfig.Degrees(scale.Value) else 0
		if degrees <= 0 then
			-- A beginner stands like a person, and writing identity every frame to say
			-- so would claim the shoulders away from the stock idle for no reason.
			self:_release(character)
			continue
		end

		entry.holding = true
		for _, bound in entry.joints do
			if bound.joint.Parent ~= nil then
				bound.joint.Transform = StanceConfig.Apply(bound.name, IDENTITY, degrees)
			end
		end
	end
end

function StanceController:_watch(character: Model)
	self:_sync(character)
	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			self:_clear(character)
		end
	end)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		-- A corpse must not keep flexing. Hard cut, as the gait and the flight pose
		-- both do on death.
		humanoid.Died:Connect(function()
			self:_clear(character)
		end)
	end
end

function StanceController:_track(player: Player)
	if player.Character ~= nil then
		self:_watch(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		self:_watch(character)
	end)
	player.CharacterRemoving:Connect(function(character: Model)
		self:_clear(character)
	end)
end

function StanceController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	-- Mobs stand too, and nothing above asks for a Player. A thief has no MuscleScales
	-- folder so it resolves to zero degrees and is released on the first frame; a boss
	-- carries BRUTE_SCALE and stands permanently spread, with no branch on either.
	local function watchMob(instance: Instance)
		if instance:IsA("Model") then
			mobs[instance] = true
		end
	end
	for _, model in CollectionService:GetTagged(MobConfig.MOB_TAG) do
		watchMob(model)
	end
	CollectionService:GetInstanceAddedSignal(MobConfig.MOB_TAG):Connect(watchMob)
	CollectionService:GetInstanceRemovedSignal(MobConfig.MOB_TAG):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			mobs[instance] = nil
			self:_clear(instance)
		end
	end)

	-- PreSimulation for the reason TrainingPoseController's header gives: the window
	-- after the animator has evaluated and before the world step reads the joints.
	RunService.PreSimulation:Connect(function()
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character ~= nil and active[character] == nil then
				self:_sync(character)
			end
		end
		for model in mobs do
			if active[model] == nil then
				self:_sync(model)
			end
		end
		self:_apply()
	end)
end

return StanceController
