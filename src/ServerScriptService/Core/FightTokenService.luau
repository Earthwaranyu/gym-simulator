--!strict
--[[
	FightTokenService — PvP-earned currency for physique transformations.

	A rewarded knockout pays exactly one Fight Token. CombatService owns kill credit,
	including Core reflection, and labels repeat-farmed kills; listening to that one
	signal keeps direct and reflected knockouts identical while making repeats pay zero.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)

local TOKENS_PER_KO = 1

local FightTokenService = {
	Name = "FightTokenService",
	Priority = 75,
}

-- (player, amountAwarded, newTotal)
FightTokenService.TokensAwarded = Signal.new()
-- (player, amountSpent, newTotal)
FightTokenService.TokensSpent = Signal.new()

local DataService: any = nil
local CombatService: any = nil

function FightTokenService:Init()
	DataService = Loader.Get("DataService")
	CombatService = Loader.Get("CombatService")
end

function FightTokenService:GetTokens(player: Player): number
	local data = DataService:GetData(player)
	return if data ~= nil then data.FightTokens else 0
end

function FightTokenService:AwardTokens(player: Player, amount: number): boolean
	local data = DataService:GetData(player)
	local whole = math.floor(amount)
	if data == nil or amount ~= amount or amount == math.huge or whole <= 0 then
		return false
	end

	data.FightTokens += whole
	DataService:MarkDirty(player)
	FightTokenService.TokensAwarded:Fire(player, whole, data.FightTokens)
	return true
end

function FightTokenService:TrySpendTokens(player: Player, amount: number): boolean
	local data = DataService:GetData(player)
	local whole = math.floor(amount)
	if data == nil or amount ~= amount or amount == math.huge or whole <= 0 or data.FightTokens < whole then
		return false
	end

	data.FightTokens -= whole
	DataService:MarkDirty(player)
	FightTokenService.TokensSpent:Fire(player, whole, data.FightTokens)
	return true
end

function FightTokenService:Start()
	CombatService.PlayerKilled:Connect(function(_victim: Player, killer: Player, isRepeatKill: boolean)
		if isRepeatKill or not self:AwardTokens(killer, TOKENS_PER_KO) then
			return
		end
		Net.Event("Notify")
			:FireClient(killer, `+{TOKENS_PER_KO} FIGHT TOKEN · {self:GetTokens(killer)} total`)
	end)

	-- Field monsters are the reliable, non-adversarial way to earn Fight Tokens. PvP
	-- pays better per kill but needs a victim who is worth killing; goblins are always
	-- there, which is what stops the physique ladder depending on other players.
	--
	-- Bosses deliberately pay nothing here: their reward is a Token lump, handled by
	-- TokenService listening to the same signal.
	Loader.Get("MobService").MobKilled:Connect(function(killer: Player, mob)
		if mob.Kind ~= "Normal" then
			return
		end
		-- Scaled by the killer's physique class, capped at what this tier is worth so a
		-- high class cannot farm starter goblins for the rest of its own ladder.
		local data = DataService:GetData(killer)
		local classLevel = if data ~= nil then data.MuscleClassLevel else 0
		local reward = (mob.FightTokenReward or 0) * MobConfig.RewardMultiplier(mob, classLevel)
		if reward <= 0 or not self:AwardTokens(killer, reward) then
			return
		end
		Net.Event("Notify"):FireClient(killer, `+{reward} FIGHT TOKEN · {self:GetTokens(killer)} total`)
	end)
end

return FightTokenService
