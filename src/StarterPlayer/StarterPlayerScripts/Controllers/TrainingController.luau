--!strict
--[[
	TrainingController — input and prompts for training stations.

	Purely presentational. It sends intent and mirrors whatever state the server pushes
	back; it never predicts a rep or a stat gain, because the server can reject either.

	Prompts are created client-side, one per tagged station, so they cost the server
	nothing and appear automatically for stations streamed in later.
]]

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

local REP_ACTION = "GymSimulatorRep"

local TrainingController = {
	Name = "TrainingController",
	Priority = 80,
}

local state: Types.TrainingState = {
	StationId = nil,
	Combo = 0,
	Stamina = 0,
	MaxStamina = 100,
}

local prompts: { [Instance]: ProximityPrompt? } = {}
local activeStation: Instance? = nil

-- (state) — fired whenever the server pushes new training state.
TrainingController.Changed = Signal.new()

function TrainingController:GetState(): Types.TrainingState
	return state
end

function TrainingController:IsTraining(): boolean
	return state.StationId ~= nil
end

local function findPromptParent(station: Instance): BasePart?
	if station:IsA("BasePart") then
		return station
	end
	if station:IsA("Model") then
		local primary = station.PrimaryPart
		if primary ~= nil then
			return primary
		end
		return station:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function TrainingController:_bindStation(station: Instance)
	if prompts[station] ~= nil then
		return
	end

	local definition, reason = EquipmentConfig.Resolve(station)
	if definition == nil then
		warn(`[TrainingController] Ignoring station {station:GetFullName()}: {reason}`)
		return
	end

	local parent = findPromptParent(station)
	if parent == nil then
		warn(`[TrainingController] Station {station:GetFullName()} has no BasePart to hold a prompt`)
		return
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = definition.DisplayName
	prompt.ActionText = definition.ActionText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent

	prompt.Triggered:Connect(function()
		if activeStation == station and state.StationId ~= nil then
			activeStation = nil
			Net.Event("TrainingStop"):FireServer()
		else
			-- Optimistic only for prompt toggling. If the server rejects the start it
			-- never pushes a training state, and the next push clears this.
			activeStation = station
			Net.Event("TrainingStart"):FireServer(station)
		end
	end)

	prompts[station] = prompt
end

function TrainingController:_unbindStation(station: Instance)
	local prompt = prompts[station]
	if prompt ~= nil then
		prompt:Destroy()
		prompts[station] = nil
	end
end

--[[
	While a set is running, any of click / space / gamepad A sends one rep. The server
	rate-limits, so holding the button down gains nothing over tapping at the machine's
	own interval.
]]
function TrainingController:_setRepInputBound(isBound: boolean)
	if isBound then
		ContextActionService:BindAction(REP_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState == Enum.UserInputState.Begin then
				Net.Event("TrainingRep"):FireServer()
			end
			return Enum.ContextActionResult.Pass
		end, false, Enum.UserInputType.MouseButton1, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
	else
		ContextActionService:UnbindAction(REP_ACTION)
	end
end

function TrainingController:Init()
	Net.Event("TrainingChanged").OnClientEvent:Connect(function(newState: Types.TrainingState)
		local wasTraining = state.StationId ~= nil
		state = newState

		local isTraining = state.StationId ~= nil
		if isTraining ~= wasTraining then
			self:_setRepInputBound(isTraining)
		end

		-- Cleared unconditionally rather than only on transition, so a rejected start
		-- or a server-side Stop cannot leave the prompt stuck in "stop" mode.
		if not isTraining then
			activeStation = nil
		end

		TrainingController.Changed:Fire(state)
	end)
end

function TrainingController:Start()
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		self:_bindStation(station)
	end

	CollectionService:GetInstanceAddedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_bindStation(station)
	end)

	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_unbindStation(station)
	end)

	local player = Players.LocalPlayer
	player.CharacterRemoving:Connect(function()
		self:_setRepInputBound(false)
		activeStation = nil
	end)
end

return TrainingController
