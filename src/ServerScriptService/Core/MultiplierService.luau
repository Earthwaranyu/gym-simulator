--!strict
--[[
	MultiplierService — per-muscle token upgrades plus physique transformations.

	Each muscle buys permanent doubling levels using tokens, with no stat requirement.
	The ordered physique path is a visual training loop: meet the next total-Power gate,
	spend its PvP-earned Fight Tokens, keep every stat, and begin the new class lean so
	each muscle group can visibly be built again.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)
local TokenMultiplierConfig = require(ReplicatedStorage.Modules.TokenMultiplierConfig)

local MODIFIER_ID = "TokenUpgrades"

local MultiplierService = { Name = "MultiplierService", Priority = 70 }
-- (player, statId, newLevel)
MultiplierService.MultiplierPurchased = Signal.new()

local DataService: any = nil
local StatService: any = nil
local TokenService: any = nil
local FightTokenService: any = nil

function MultiplierService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	TokenService = Loader.Get("TokenService")
	FightTokenService = Loader.Get("FightTokenService")

	Net.BindFunction("PurchaseMultiplier", 4, function(player: Player, statId: any)
		if type(statId) ~= "string" then
			return false, "Choose a muscle multiplier first."
		end
		return self:Purchase(player, statId)
	end)

	Net.BindFunction("SelectPhysiqueClass", 4, function(player: Player, requestedLevel: any)
		if type(requestedLevel) ~= "number" then
			return false, "Invalid physique."
		end
		return self:SelectPhysique(player, requestedLevel)
	end)
end

function MultiplierService:Start()
	DataService.ProfileLoaded:Connect(function(player: Player)
		self:_refresh(player)
	end)
	for _, player in Players:GetPlayers() do
		if DataService:GetData(player) ~= nil then
			self:_refresh(player)
		end
	end
end

function MultiplierService:_refresh(player: Player)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end
	local multipliers: { [Types.StatId]: number } = {}
	for _, definition in StatConfig.List do
		multipliers[definition.Id] =
			TokenMultiplierConfig.Multiplier(data.MultiplierLevels[definition.Id] or 0)
	end
	StatService:SetModifier(player, { Id = MODIFIER_ID, Multipliers = multipliers })
end

function MultiplierService:GetLevel(player: Player, statId: Types.StatId): number
	local data = DataService:GetData(player)
	return if data ~= nil then (data.MultiplierLevels[statId] or 0) else 0
end

function MultiplierService:GetNextCost(player: Player, statId: Types.StatId): number
	local nextLevel = TokenMultiplierConfig.Next(self:GetLevel(player, statId))
	return if nextLevel ~= nil then nextLevel.CostToUnlock else 0
end

function MultiplierService:Purchase(player: Player, statId: Types.StatId): (boolean, string)
	local definition = StatConfig.Get(statId)
	if definition == nil then
		return false, "That muscle does not exist."
	end
	local data = DataService:GetData(player)
	if data == nil then
		return false, "Your data is still loading."
	end

	local level = data.MultiplierLevels[statId] or 0
	local nextLevel = TokenMultiplierConfig.Next(level)
	if nextLevel == nil then
		return false, `{definition.DisplayName} already owns the maximum safe multiplier.`
	end
	if not TokenService:TrySpendTokens(player, nextLevel.CostToUnlock) then
		return false, `You need {NumberFormat.Format(nextLevel.CostToUnlock)} tokens for this upgrade.`
	end

	data.MultiplierLevels[statId] = level + 1
	self:_refresh(player)
	DataService:MarkDirty(player)
	MultiplierService.MultiplierPurchased:Fire(player, statId, level + 1)
	return true, `{definition.DisplayName} gains are now ×{NumberFormat.FormatGain(nextLevel.Multiplier)}`
end

function MultiplierService:SelectPhysique(player: Player, requestedLevel: number): (boolean, string)
	local data = DataService:GetData(player)
	if data == nil then
		return false, "Your data is still loading."
	end
	local currentLevel = math.clamp(math.floor(data.MuscleClassLevel), 0, MuscleClassConfig.MAX_LEVEL)
	local nextClass = MuscleClassConfig.Next(currentLevel)
	if nextClass == nil then
		return false, "You already own the final physique class."
	end
	if requestedLevel ~= nextClass.Level then
		return false, `Transform into {nextClass.DisplayName} next. Physique classes cannot be skipped.`
	end
	local power = StatService:GetTotalPower(player)
	if power < nextClass.RequiredPower then
		return false,
			`Reach {NumberFormat.Format(nextClass.RequiredPower)} Power to transform into {nextClass.DisplayName}.`
	end
	if data.FightTokens < nextClass.FightTokenCost then
		local needed = nextClass.FightTokenCost - data.FightTokens
		return false,
			`Earn {needed} more Fight {if needed == 1 then "Token" else "Tokens"} from rewarded KOs.`
	end

	local TrainingService = Loader.Get("TrainingService")
	if TrainingService:IsTraining(player) then
		TrainingService:Stop(player)
	end
	if not FightTokenService:TrySpendTokens(player, nextClass.FightTokenCost) then
		return false, "Your Fight Token balance changed. Try again."
	end

	-- Transforming takes no progression away, but begins a new visual growth pass.
	--
	-- This used to zero all five stats and respawn the player at the starter beach, on
	-- the rebirth logic that a physique is a fresh run. It is not: the Fight Token cost
	-- and the Power gate are already the price, and charging a second time in lost
	-- progress made the upgrade something players avoided rather than worked toward.
	-- Stats, selected weights, tokens, multiplier levels and titles all carry over. A
	-- baseline snapshot is what makes the body lean again: future size is earned from
	-- the difference between each lifetime stat and the value captured here.
	for _, definition in StatConfig.List do
		data.PhysiqueStatBaselines[definition.Id] = data.Stats[definition.Id] or 0
	end
	data.MuscleClassLevel = nextClass.Level
	DataService:MarkDirty(player)

	-- No stat changed, so refresh the two visual systems directly. MuscleService sends
	-- scale 1 for every group and AppearanceService paints the new class colour.
	Loader.Get("MuscleService"):Refresh(player)
	Loader.Get("AppearanceService"):Refresh(player)

	return true,
		`{nextClass.DisplayName} unlocked for {nextClass.FightTokenCost} Fight Tokens. Your power is safe; build the new physique.`
end

return MultiplierService
