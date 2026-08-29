--!strict
--[[
	CombatController — ability input and target selection.

	Picks a target and sends intent. The server re-validates range, cooldown and
	liveness, so the worst a modified client achieves is asking for hits it will not
	get.

	Target selection uses the nearest living player in a forgiving sphere. Camera aim
	is intentionally irrelevant: a close-range punch should not miss because the
	crosshair is a few pixels beside a large avatar.

	Every binding here is read out of AbilityConfig rather than written down. That is
	the whole reason this file stopped being about Punch specifically: it used to hold
	one hardcoded ability id, one hardcoded cooldown mirror and one bind, so the second
	ability would have needed a second copy of all three and the fourth would have
	needed a fourth. Now a new ability is a row in that table.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Net = require(ReplicatedStorage.Modules.Net)
local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)

local ACTION_PREFIX = "GymSimulatorAbility"
local DEFAULT_ABILITY = "Punch"
-- A generous close-combat sphere. Eighteen studs lets the enlarged muscle classes and
-- fast anime lunge connect without requiring two HumanoidRootParts to overlap.
local TARGET_RANGE = 18

local CombatController = {
	Name = "CombatController",
	Priority = 70,
}

-- (feedback) — Hit, Hurt, Blocked, or Rejected payloads from the server.
CombatController.Feedback = Signal.new()

-- When the local copy of each ability's cooldown expires. Per ability rather than one
-- shared timer: a slam on cooldown must not also swallow the punch you throw while
-- waiting for it.
local readyAt: { [string]: number } = {}

local function getRoot(character: Model?): BasePart?
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function isAlive(character: Model?): boolean
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[
	The player the local character is most plausibly attacking, or nil.
]]
function CombatController:FindTarget(): Player?
	local localPlayer = Players.LocalPlayer
	local myRoot = getRoot(localPlayer.Character)
	if myRoot == nil or not isAlive(localPlayer.Character) then
		return nil
	end

	local best: Player? = nil
	local bestDistance = math.huge

	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end

		local otherRoot = getRoot(other.Character)
		if otherRoot == nil or not isAlive(other.Character) then
			continue
		end

		local offset = otherRoot.Position - myRoot.Position
		local distance = offset.Magnitude
		if distance > TARGET_RANGE or distance <= 0 then
			continue
		end

		if distance < bestDistance then
			bestDistance = distance
			best = other
		end
	end

	return best
end

--[[
	Asks the server to fire an ability, unless it already knows the answer is no.

	The left mouse button both trains and punches, so this runs on every click of a held
	button — several a second. Sending each one produced a rejection back for every click
	inside the cooldown, and at eight events a second it also crowded the remote's own
	rate limit. Declining locally costs nothing and the server still re-checks: the worst
	a client that removes this achieves is asking for hits it will not get.

	The cooldown is the only thing declined locally. Having no target is not — see below.
]]
function CombatController:Activate(abilityId: string)
	local entry = AbilityConfig.Get(abilityId)
	if entry == nil then
		return
	end
	if os.clock() < (readyAt[abilityId] or 0) then
		return
	end

	-- Sent whether or not anyone is in reach. A swing at nothing is still a swing:
	-- the server throws the animation on every one of them and only resolves damage
	-- when a target came with it, so pressing attack in an empty gym does something.
	-- FindTarget returning nil is a miss, not a reason to stay still.
	readyAt[abilityId] = os.clock() + entry.Cooldown
	Net.Event("AbilityActivate"):FireServer(abilityId, self:FindTarget())
end

--[[
	Seconds left on an ability's local cooldown, and its full length.

	Exposed for the HUD's cooldown sweep. The HUD reads this rather than keeping its own
	timers, so the sweep can never disagree with the input that is actually being
	declined — a slot that looks ready while the controller is refusing the press is a
	bug players read as the game dropping inputs.
]]
function CombatController:CooldownRemaining(abilityId: string): (number, number)
	local entry = AbilityConfig.Get(abilityId)
	if entry == nil or entry.Cooldown <= 0 then
		return 0, 0
	end
	return math.max((readyAt[abilityId] or 0) - os.clock(), 0), entry.Cooldown
end

--[[
	The ordinary attack.

	Kept as a named method, and kept meaning Punch, because HudController has thrown one
	of these on every left click since the training dock arrived. Making that call site
	learn about ability ids to keep doing the one thing it has always done would be a
	change to a consumer for no gain.
]]
function CombatController:Attack()
	self:Activate(DEFAULT_ABILITY)
end

--[[
	Reports a held ability starting or stopping. Block is the only one today.

	Held abilities do not go through AbilityActivate: that remote fires a move once, and
	a guard is a state with a beginning and an end. BlockService owns the meter and drops
	the guard itself when it empties, so a client that never sends `false` gets one
	meter's worth of guard and then a break.
]]
function CombatController:SetHeld(abilityId: string, held: boolean)
	if abilityId == "Block" then
		Net.Event("BlockChanged"):FireServer(held)
	end
end

function CombatController:Init()
	Net.Event("CombatFeedback").OnClientEvent:Connect(function(payload: any)
		CombatController.Feedback:Fire(payload)
	end)
end

--[[
	Binds one ability's key, gamepad button and touch button.

	ContextActionService rather than UserInputService because it is what creates the
	on-screen button for touch, and a phone with three abilities and no buttons for two
	of them is not a build anybody can play.
]]
function CombatController:_bind(entry: AbilityConfig.AbilityEntry)
	local keys: { Enum.KeyCode } = {}
	for _, name in { entry.KeyCode, entry.GamepadKeyCode } do
		if name ~= nil then
			local keyCode = (Enum.KeyCode :: any)[name]
			if keyCode ~= nil then
				table.insert(keys, keyCode)
			else
				warn(`[CombatController] {entry.Id} names an unknown key "{name}"`)
			end
		end
	end
	if #keys == 0 then
		return
	end

	local action = ACTION_PREFIX .. entry.Id
	ContextActionService:BindAction(action, function(_, inputState: Enum.UserInputState)
		if entry.Kind == "Hold" then
			if inputState == Enum.UserInputState.Begin then
				self:SetHeld(entry.Id, true)
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				self:SetHeld(entry.Id, false)
			end
		elseif inputState == Enum.UserInputState.Begin then
			self:Activate(entry.Id)
		end
		-- Passed rather than sunk so a key that also means something to another
		-- controller keeps meaning it. Nothing here owns a key exclusively.
		return Enum.ContextActionResult.Pass
	end, true, table.unpack(keys))

	ContextActionService:SetTitle(action, entry.DisplayName)
end

function CombatController:Start()
	-- Punch keeps no keyboard key of its own. It is the left mouse button and has been
	-- since the training dock arrived — HudController throws one on click whenever the
	-- fist slot is selected — and a second way to do the same thing meant the HUD had
	-- to advertise a key nobody needed. Its gamepad button and touch button still get
	-- bound below, because neither of those inputs has a left mouse button, and neither
	-- is gated on the selected slot: a Punch button that silently does nothing while
	-- slot 3 is up is worse on a phone than an ungated one.
	for _, entry in AbilityConfig.Ordered() do
		self:_bind(entry)
	end

	-- A guard has to end when the character does. Without this, dying mid-block leaves
	-- the server holding a raised guard for a character that no longer exists, and the
	-- next respawn starts with a meter quietly draining behind an invisible barrier.
	local function dropGuardOnDeath(character: Model)
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return
		end
		humanoid.Died:Connect(function()
			self:SetHeld("Block", false)
		end)
	end

	local localPlayer = Players.LocalPlayer
	if localPlayer.Character ~= nil then
		dropGuardOnDeath(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(dropGuardOnDeath)
end

return CombatController
