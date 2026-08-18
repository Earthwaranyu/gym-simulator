--!strict
--[[
	FlinchController — makes a body react to being hit.

	The fifth pose controller, and the only one driven by something happening *to* a
	character rather than something they chose to do. Until now the victim of a punch
	showed no sign of it at all: a number appeared on their screen and their body carried
	on exactly as before. In a game whose entire hook is interrupting somebody
	mid-training, the person being interrupted was the one character in the fight who
	never moved.

	Reads the HurtAt stamp CombatService writes on the victim — see FlinchConfig's header
	for why the victim carries it and not the attacker — picks a flinch by impact band,
	and blends it in fast and out slow. Everything else is the established shape: bind the
	joints once, write on PreSimulation, clear to identity when it expires.

	Whether a flinch interrupts your own swing is a rule, not a side effect of load order.

	The first build tried to express it as a priority — 6.5, between the gait and the
	strikes — on the theory that the last writer on PreSimulation wins. Measured in
	Studio, the flinch won anyway: at the moment a clean punch drives the shoulder to
	108 degrees, a flinch stamped mid-swing put it at 34. Ordering between controllers is
	not something to lean on, so the rule is written down instead.

	The rule: **a crushing hit interrupts your swing, a lighter one does not.** Trading
	jabs is the common case and two players flinching through each other's combos would
	leave neither punch legible — but a hit that lands in the top band should stop you,
	because a finisher that could be ignored is not a finisher. That is a better rule
	than "the flinch always loses", which was the original plan and would have meant two
	players fighting each other never visibly reacted at all.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local FlinchConfig = require(ReplicatedStorage.Modules.FlinchConfig)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local FlinchController = {
	Name = "FlinchController",
	-- Between the gait (7) and the strikes (6) as a statement of intent. Nothing here
	-- depends on it — the interrupt rule is enforced explicitly in _begin, because
	-- measurement showed controller write order is not reliable enough to encode a
	-- gameplay rule in.
	Priority = 6.5,
}

local IDENTITY: CFrame = CFrame.identity

-- Past this a flinch is a few pixels of shoulder movement on a character too far away to
-- be fighting you. Tighter than the pose controllers because this fires far more often.
local CULL_DISTANCE = 160

type Bound = { name: string, joint: any }

type Entry = {
	flinch: FlinchConfig.Flinch,
	motions: { any },
	joints: { Bound },
	startedAt: number,
}

local active: { [Model]: Entry } = {}

local function bindJoints(character: Model): { Bound }
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return {}
	end

	local bound: { Bound } = {}
	for _, name in FlinchConfig.Joints do
		local joint = PosePlayback.FindJoint(character, humanoid.RigType, name)
		if joint ~= nil then
			table.insert(bound, { name = name, joint = joint })
		end
	end
	return bound
end

function FlinchController:_clear(character: Model)
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
	How strongly the flinch is applied, this many seconds in.

	In fast, held, out slow. The asymmetry is the entire read: a symmetric curve makes a
	victim look like they decided to lean rather than like they were hit.
]]
local function strengthAt(flinch: FlinchConfig.Flinch, elapsed: number): number
	if elapsed < flinch.BlendInSeconds then
		return elapsed / flinch.BlendInSeconds
	end
	local held = flinch.BlendInSeconds + flinch.HoldSeconds
	if elapsed < held then
		return 1
	end
	local out = (elapsed - held) / flinch.BlendOutSeconds
	if out >= 1 then
		return 0
	end
	-- Smoothstep on the way out, so the body settles rather than stopping dead on the
	-- frame the flinch expires.
	local t = 1 - out
	return t * t * (3 - 2 * t)
end

function FlinchController:_apply()
	local camera = workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else Vector3.zero
	local now = os.clock()

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local elapsed = now - entry.startedAt
		if elapsed >= FlinchConfig.Duration(entry.flinch) then
			self:_clear(character)
			continue
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") and (root.Position - eye).Magnitude > CULL_DISTANCE then
			self:_clear(character)
			continue
		end

		local strength = strengthAt(entry.flinch, elapsed)
		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end
			for _, motion in entry.motions do
				if motion.Joint ~= bound.name then
					continue
				end
				-- Alpha 0 because Rest equals Peak: a flinch holds a shape rather than
				-- cycling through one, exactly as the flight silhouettes do.
				bound.joint.Transform = IDENTITY:Lerp(PosePlayback.PoseAt(motion, 0), strength)
				break
			end
		end
	end
end

--[[
	Starts a flinch, replacing any already running.

	Replacing rather than queueing, because the three contacts of a combo arrive a fifth
	of a second apart and a queue would still be playing the jab when the finisher landed.
	The newest hit is the one worth showing.
]]
function FlinchController:_begin(character: Model)
	local weight = character:GetAttribute(FlinchConfig.HURT_IMPACT_ATTRIBUTE)
	local tier = Formulas.ImpactTier(if type(weight) == "number" then weight else 0)
	local flinch = FlinchConfig.Get(tier)
	if flinch == nil then
		return
	end

	-- Mid-swing, only a crushing hit gets through. See the header for why this is a
	-- stated rule rather than a controller priority.
	if tier ~= "Crushing" then
		local strikeAt = character:GetAttribute(StrikeConfig.STRIKE_ATTRIBUTE)
		if type(strikeAt) == "number" then
			local strikeId = character:GetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE)
			local strike = if type(strikeId) == "string" then StrikeConfig.Get(strikeId) else nil
			if strike ~= nil and workspace:GetServerTimeNow() - strikeAt < strike.Duration then
				return
			end
		end
	end

	local existing = active[character]
	local joints = if existing ~= nil then existing.joints else bindJoints(character)
	if #joints == 0 then
		return
	end

	active[character] = {
		flinch = flinch,
		motions = FlinchConfig.Motions(flinch),
		joints = joints,
		startedAt = os.clock(),
	}
end

function FlinchController:_watch(character: Model)
	character:GetAttributeChangedSignal(FlinchConfig.HURT_AT_ATTRIBUTE):Connect(function()
		if type(character:GetAttribute(FlinchConfig.HURT_AT_ATTRIBUTE)) ~= "number" then
			return
		end
		self:_begin(character)
	end)

	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			self:_clear(character)
		end
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		-- A corpse does not flinch. Hard cut, as the other controllers do on death.
		humanoid.Died:Connect(function()
			self:_clear(character)
		end)
	end
end

function FlinchController:_track(player: Player)
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

function FlinchController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	-- Mobs flinch too. CombatService stamps any model it damages, and a goblin that
	-- stood perfectly still while being beaten would be the one thing in the fight not
	-- reacting. A rig without the joints a flinch names simply binds nothing and is
	-- skipped, so this costs nothing for a mob built out of parts.
	for _, model in CollectionService:GetTagged(MobConfig.MOB_TAG) do
		if model:IsA("Model") then
			self:_watch(model)
		end
	end
	CollectionService:GetInstanceAddedSignal(MobConfig.MOB_TAG):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			self:_watch(instance)
		end
	end)

	RunService.PreSimulation:Connect(function()
		self:_apply()
	end)
end

return FlinchController
