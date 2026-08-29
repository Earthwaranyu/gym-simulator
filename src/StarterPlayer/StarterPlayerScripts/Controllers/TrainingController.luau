--!strict
--[[
	TrainingController — the client's view of what the player is training.

	Training is automatic and entirely server-driven: holding E on a station mounts
	the player, and reps tick on their own. This controller reads that state for the
	HUD, and also lets the player cancel training by pressing Space or jumping —
	those fire a lightweight StopTraining remote that the server validates.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local TrainingController = {
	Name = "TrainingController",
	Priority = 80,
}

local state: Types.TrainingState = {
	StationId = nil,
	Combo = 0,
	StaggerSeconds = 0,
	ZoneId = nil,
	WeightKg = 0,
	MinWeightKg = 0,
	MaxWeightKg = 0,
	StepWeightKg = 0,
	RecommendedWeightKg = 0,
	WeightMultiplier = 1,
	RequiredStat = 0,
	AutoLoadEnabled = false,
	HasAutoLoad = false,
}

-- os.clock() when the current state arrived, so the stagger can be counted down
-- locally rather than the server streaming a timer.
local receivedAt = 0

-- (state) — fired whenever the server pushes new training state.
TrainingController.Changed = Signal.new()
-- Fired before a local stop request crosses the network. Visual pose cleanup listens
-- to this so a floor exercise releases on the key press instead of waiting for the
-- server attribute round trip. The server still owns the real session and movement.
TrainingController.StopRequested = Signal.new()

function TrainingController:GetState(): Types.TrainingState
	return state
end

function TrainingController:IsTraining(): boolean
	return state.StationId ~= nil
end

--[[
	Seconds left before the player can train again after being hit. Zero when free.
]]
function TrainingController:GetStaggerRemaining(): number
	if state.StaggerSeconds <= 0 then
		return 0
	end
	return math.max(0, state.StaggerSeconds - (os.clock() - receivedAt))
end

--[[
	Asks the server to stop the current training session. Called when the player
	presses Space or jumps. The server re-checks that they are actually training;
	a spoofed call by a non-training player is a harmless no-op.
]]
function TrainingController:RequestStop()
	if not self:IsTraining() then
		return
	end
	TrainingController.StopRequested:Fire()
	Net.Event("StopTraining"):FireServer()
end

function TrainingController:Init()
	Net.Event("TrainingChanged").OnClientEvent:Connect(function(newState: Types.TrainingState)
		state = newState
		receivedAt = os.clock()
		TrainingController.Changed:Fire(state)
	end)
end

function TrainingController:Start()
	-- Holding E is handled by Roblox's ProximityPrompt on the server rather than by
	-- RequestStop. Mirror its successful local trigger into the same visual-release
	-- signal. This also covers switching directly from one nearby machine to another.
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= Players.LocalPlayer or not self:IsTraining() then
			return
		end
		local current: Instance? = prompt.Parent
		while current ~= nil do
			if CollectionService:HasTag(current, EquipmentConfig.STATION_TAG) then
				TrainingController.StopRequested:Fire()
				return
			end
			current = current.Parent
		end
	end)

	-- Space key: cancel training. gameProcessedEvent is respected so typing in chat
	-- does not dismount the player.
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space then
			self:RequestStop()
		end
	end)

	-- Also watch for jumps triggered by mobile or gamepad (Humanoid.StateChanged),
	-- which may not come through as a Space key press.
	local player = Players.LocalPlayer
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.StateChanged:Connect(function(_old: Enum.HumanoidStateType, new: Enum.HumanoidStateType)
				if new == Enum.HumanoidStateType.Jumping then
					self:RequestStop()
				end
			end)
		end
	end

	if player.Character then
		watchCharacter(player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)
end

return TrainingController
