--!strict
--[[
	TrainingService — server-authoritative training sets.

	The client sends intent only ("I want to start", "I did a rep"). Every gain, every
	stamina cost, and every validity check happens here, so a modified client can at
	best spam remotes and get rejected.

	Stations are bound by CollectionService tag, so a level designer adds machines
	without touching code — see EquipmentConfig for the tag and attribute contract.

	This also owns the combo, which is what makes the PvP hook bite: reps build a
	multiplier up to 2x, and Interrupt() drops it back to zero. Being punched mid-set
	costs a player their built-up rate, not their saved progress.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

-- How far a player may drift from a station before the set is cancelled.
local MAX_STATION_DISTANCE = 18
-- Reps land slightly early under lag; allow a margin before treating it as cheating.
local REP_INTERVAL_TOLERANCE = 0.85
-- Combo grows this much per rep...
local COMBO_STEP = 0.02
-- ...up to this multiplier.
local MAX_COMBO_MULTIPLIER = 2

type Session = {
	station: Instance,
	definition: EquipmentConfig.EquipmentDefinition,
	combo: number,
	lastRepAt: number,
}

local TrainingService = {
	Name = "TrainingService",
	Priority = 40,
}

local sessions: { [Player]: Session } = {}

local DataService: any = nil
local StatService: any = nil
local StaminaService: any = nil

-- (player, session-or-nil) — fired whenever a player starts, stops, or reps.
TrainingService.TrainingChanged = Signal.new()

function TrainingService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	StaminaService = Loader.Get("StaminaService")
end

local function getRoot(player: Player): BasePart?
	local character = player.Character
	if character == nil then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function getStationPosition(station: Instance): Vector3?
	if station:IsA("BasePart") then
		return station.Position
	end
	if station:IsA("Model") then
		local pivotOk, pivot = pcall(function()
			return station:GetPivot().Position
		end)
		if pivotOk then
			return pivot
		end
	end
	return nil
end

--[[
	The combo multiplier a session has built up. Exposed so the HUD can show it.
]]
function TrainingService:GetComboMultiplier(player: Player): number
	local session = sessions[player]
	if session == nil then
		return 1
	end
	return math.min(MAX_COMBO_MULTIPLIER, 1 + session.combo * COMBO_STEP)
end

function TrainingService:GetSession(player: Player): Session?
	return sessions[player]
end

function TrainingService:IsTraining(player: Player): boolean
	return sessions[player] ~= nil
end

local function buildState(player: Player, session: Session?): Types.TrainingState
	return {
		StationId = if session ~= nil then session.definition.Id else nil,
		Combo = if session ~= nil then session.combo else 0,
		Stamina = StaminaService:Get(player),
		MaxStamina = StaminaService:GetMax(player),
	}
end

function TrainingService:_push(player: Player)
	local session = sessions[player]
	Net.Event("TrainingChanged"):FireClient(player, buildState(player, session))
	TrainingService.TrainingChanged:Fire(player, session)
end

--[[
	Begins a set. Returns false when rejected; the client is told via TrainingChanged
	rather than a return value, since the request arrives over a RemoteEvent.

	Named BeginSet rather than Start so it cannot collide with the Loader's Start()
	lifecycle method on this same table.
]]
function TrainingService:BeginSet(player: Player, station: Instance): boolean
	if not CollectionService:HasTag(station, EquipmentConfig.STATION_TAG) then
		return false
	end

	local definition, reason = EquipmentConfig.Resolve(station)
	if definition == nil then
		warn(`[TrainingService] Station {station:GetFullName()} is misconfigured: {reason}`)
		return false
	end

	local root = getRoot(player)
	local position = getStationPosition(station)
	if root == nil or position == nil then
		return false
	end
	if (root.Position - position).Magnitude > MAX_STATION_DISTANCE then
		return false
	end

	if DataService:GetData(player) == nil then
		return false
	end
	if StatService:GetTotalPower(player) < definition.UnlockPower then
		return false
	end

	-- One player per station, so a machine cannot be shared or camped.
	for otherPlayer, session in sessions do
		if session.station == station and otherPlayer ~= player then
			return false
		end
	end

	sessions[player] = {
		station = station,
		definition = definition,
		combo = 0,
		lastRepAt = 0,
	}

	StaminaService:SetRegenSuppressed(player, true)
	self:_push(player)

	return true
end

--[[
	Ends a set cleanly. Safe to call for a player who is not training.
]]
function TrainingService:Stop(player: Player)
	if sessions[player] == nil then
		return
	end

	sessions[player] = nil
	StaminaService:SetRegenSuppressed(player, false)
	self:_push(player)
end

--[[
	Breaks the combo without ending the set, and drains stamina.

	This is the training interrupt — the mechanic the whole game is built around.
	CombatService calls it when a training player is hit, so attacking someone
	mid-set costs them their built-up rate and their stamina buffer.
]]
function TrainingService:Interrupt(player: Player, staminaPenalty: number?)
	local session = sessions[player]
	if session == nil then
		return
	end

	session.combo = 0

	if staminaPenalty ~= nil and staminaPenalty > 0 then
		StaminaService:Drain(player, staminaPenalty)
	end

	self:_push(player)
end

--[[
	Processes one rep. Rejects reps that are too fast, too far away, or unaffordable,
	then awards the stat through StatService so the multiplier stack applies.
]]
function TrainingService:PerformRep(player: Player): boolean
	local session = sessions[player]
	if session == nil then
		return false
	end

	local definition = session.definition
	local now = os.clock()

	-- Rate limit. Doubles as the anti-autoclicker check, so there is no separate
	-- exploit path to close here.
	if now - session.lastRepAt < definition.RepInterval * REP_INTERVAL_TOLERANCE then
		return false
	end

	local root = getRoot(player)
	local position = getStationPosition(session.station)
	if root == nil or position == nil or (root.Position - position).Magnitude > MAX_STATION_DISTANCE then
		self:Stop(player)
		return false
	end

	local coreStat = StatService:GetStat(player, "Core")
	local staminaCost = Formulas.StaminaCost(definition.StaminaCost, coreStat)

	if not StaminaService:TrySpend(player, staminaCost) then
		-- Out of gas: end the set rather than silently dropping inputs.
		self:Stop(player)
		return false
	end

	session.lastRepAt = now
	session.combo += 1

	local baseGain = definition.BaseGain * self:GetComboMultiplier(player)
	StatService:AddStat(player, definition.StatId, baseGain)

	self:_push(player)
	return true
end

function TrainingService:Start()
	Net.Event("TrainingStart").OnServerEvent:Connect(function(player: Player, station: any)
		if typeof(station) == "Instance" then
			self:BeginSet(player, station)
		end
	end)

	Net.Event("TrainingStop").OnServerEvent:Connect(function(player: Player)
		self:Stop(player)
	end)

	Net.Event("TrainingRep").OnServerEvent:Connect(function(player: Player)
		self:PerformRep(player)
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(character: Model)
			-- Dying always ends the set, which is what forfeits the combo on death.
			self:Stop(player)

			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid ~= nil and humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					self:Stop(player)
				end)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		sessions[player] = nil
	end)
end

return TrainingService
