--!strict
--[[
	TrainingService — automatic, server-authoritative training.

	Walking up to a machine starts training; walking away stops it. There is no input
	to press and no stamina to spend, so the loop is idle-style: stand near equipment
	and the stat climbs on its own.

	Everything still happens server-side. The client sends nothing at all now — it only
	receives state to display — so there is no remote for an exploiter to spam and no
	rep rate to forge.

	Stations are bound by CollectionService tag, so a level designer adds machines
	without touching code (see EquipmentConfig for the tag and attribute contract).

	The combo is what the PvP hook attacks. Reps build a multiplier up to 2x, and
	Interrupt() both resets it and knocks the player off the machine for a few seconds.
	Since training is automatic and free, that stagger is now the entire cost of being
	attacked mid-set — without it, being punched would cost a victim nothing at all.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)

-- How close a player must be for a machine to pick them up.
local AUTO_TRAIN_RANGE = 12
-- How long being hit keeps a player off the machine.
local STAGGER_SECONDS = 3
-- Combo grows this much per rep...
local COMBO_STEP = 0.02
-- ...up to this multiplier.
local MAX_COMBO_MULTIPLIER = 2
-- Ceiling on how often mid-set combo updates are pushed to a client.
local PUSH_INTERVAL = 0.25

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
local staggeredUntil: { [Player]: number } = {}
local lastPushAt: { [Player]: number } = {}

local DataService: any = nil
local StatService: any = nil

-- (player, session-or-nil) — fired whenever a player starts, stops, or reps.
TrainingService.TrainingChanged = Signal.new()

function TrainingService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
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

function TrainingService:GetStaggerRemaining(player: Player): number
	local until_ = staggeredUntil[player]
	if until_ == nil then
		return 0
	end
	return math.max(0, until_ - os.clock())
end

local function buildState(player: Player, session: Session?): Types.TrainingState
	return {
		StationId = if session ~= nil then session.definition.Id else nil,
		Combo = if session ~= nil then session.combo else 0,
		StaggerSeconds = TrainingService:GetStaggerRemaining(player),
	}
end

function TrainingService:_push(player: Player)
	lastPushAt[player] = os.clock()
	local session = sessions[player]
	Net.Event("TrainingChanged"):FireClient(player, buildState(player, session))
	TrainingService.TrainingChanged:Fire(player, session)
end

--[[
	Ends a set. Safe to call for a player who is not training.
]]
function TrainingService:Stop(player: Player)
	if sessions[player] == nil then
		return
	end

	sessions[player] = nil
	self:_push(player)
end

--[[
	Knocks a player off their machine and resets their combo.

	This is the training interrupt, and the whole reason PvP exists in this game.
	CombatService calls it whenever a training player is hit. Because training is
	otherwise automatic and costless, the stagger is what makes attacking someone
	mid-set actually annoying.
]]
function TrainingService:Interrupt(player: Player)
	local wasTraining = sessions[player] ~= nil

	staggeredUntil[player] = os.clock() + STAGGER_SECONDS
	sessions[player] = nil

	if wasTraining then
		Net.Event("Notify"):FireClient(player, "Knocked off the machine!")
	end

	self:_push(player)
end

--[[
	Whether a machine is usable: either the player has out-levelled its power gate, or
	they bought the pass for it in the shop.
]]
function TrainingService:_isUnlocked(player: Player, definition: EquipmentConfig.EquipmentDefinition): boolean
	if StatService:GetTotalPower(player) >= definition.UnlockPower then
		return true
	end

	local data = DataService:GetData(player)
	return data ~= nil and data.OwnedEquipment[definition.Id] == true
end

--[[
	Finds the nearest tagged station the player is close enough to use, or nil.

	Stations are shared: several players can train at the same machine. Making them
	exclusive would mean walking up and silently getting nothing, which reads as a bug
	when there is no button to press.
]]
function TrainingService:_findStation(player: Player): (Instance?, EquipmentConfig.EquipmentDefinition?)
	local root = getRoot(player)
	if root == nil then
		return nil, nil
	end

	local bestStation: Instance? = nil
	local bestDefinition: EquipmentConfig.EquipmentDefinition? = nil
	local bestDistance = AUTO_TRAIN_RANGE

	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		local position = getStationPosition(station)
		if position == nil then
			continue
		end

		local distance = (root.Position - position).Magnitude
		if distance > bestDistance then
			continue
		end

		local definition = EquipmentConfig.Resolve(station)
		if definition == nil then
			continue
		end
		if not self:_isUnlocked(player, definition) then
			continue
		end

		bestStation = station
		bestDefinition = definition
		bestDistance = distance
	end

	return bestStation, bestDefinition
end

--[[
	One tick of the automatic loop for a single player: pick up a nearby machine, drop
	one they walked away from, and award reps at the machine's own interval.
]]
function TrainingService:_step(player: Player, now: number)
	if self:GetStaggerRemaining(player) > 0 then
		if sessions[player] ~= nil then
			self:Stop(player)
		end
		return
	end

	if DataService:GetData(player) == nil then
		return
	end

	local foundStation, foundDefinition = self:_findStation(player)
	local session = sessions[player]

	if foundStation == nil or foundDefinition == nil then
		if session ~= nil then
			self:Stop(player)
		end
		return
	end

	-- Rebound through explicitly typed locals: the type checker does not carry the
	-- nil-narrowing above across a multiple-return assignment.
	local station: Instance = foundStation
	local definition: EquipmentConfig.EquipmentDefinition = foundDefinition

	if session == nil or session.station ~= station then
		-- Switching machines starts a fresh combo, so a player cannot carry a built-up
		-- multiplier between stations.
		sessions[player] = {
			station = station,
			definition = definition,
			combo = 0,
			lastRepAt = now,
		}
		self:_push(player)
		return
	end

	if now - session.lastRepAt < definition.RepInterval then
		return
	end

	session.lastRepAt = now
	session.combo += 1

	local baseGain = definition.BaseGain * self:GetComboMultiplier(player)
	StatService:AddStat(player, definition.StatId, baseGain)

	-- Reps land several times a second; the client does not need every one.
	if now - (lastPushAt[player] or 0) >= PUSH_INTERVAL then
		self:_push(player)
	end
end

function TrainingService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			-- Dying always ends the set, which is what forfeits the combo on death.
			self:Stop(player)
			staggeredUntil[player] = nil

			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid ~= nil and humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					self:Stop(player)
				end)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		sessions[player] = nil
		staggeredUntil[player] = nil
		lastPushAt[player] = nil
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for _, player in Players:GetPlayers() do
			self:_step(player, now)
		end
	end)
end

return TrainingService
