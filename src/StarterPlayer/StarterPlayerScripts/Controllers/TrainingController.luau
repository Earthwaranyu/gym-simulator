--!strict
--[[
	TrainingController — the client's view of what the player is training.

	Training is automatic and entirely server-driven: walking near a machine starts it,
	walking away stops it. So this controller sends nothing at all. It exists purely so
	the HUD has somewhere to read current state from, and so a panel built later still
	shows correct values if it loads after the first push.

	There is no prompt to trigger and no rep input to bind — with no remote to call,
	there is nothing here for an exploiter to abuse.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

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

function TrainingController:Init()
	Net.Event("TrainingChanged").OnClientEvent:Connect(function(newState: Types.TrainingState)
		state = newState
		receivedAt = os.clock()
		TrainingController.Changed:Fire(state)
	end)
end

return TrainingController
