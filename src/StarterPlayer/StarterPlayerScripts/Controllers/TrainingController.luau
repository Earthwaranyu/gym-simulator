--!strict
--[[
	TrainingController — the client's view of what the player is training.

	Training is automatic and entirely server-driven: holding E on a station mounts
	the player, and reps tick on their own. This controller reads that state for the
	HUD, and also lets the player cancel training by pressing Space or jumping —
	those fire a lightweight StopTraining remote that the server validates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Packages.Signal)
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
}

-- os.clock() when the current state arrived, so the stagger can be counted down
-- locally rather than the server streaming a timer.
local receivedAt = 0

-- (state) — fired whenever the server pushes new training state.
TrainingController.Changed = Signal.new()

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
