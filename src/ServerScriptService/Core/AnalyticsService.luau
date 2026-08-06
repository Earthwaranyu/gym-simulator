--!strict
--[[
	AnalyticsService — the onboarding funnel and economy events.

	Listens to existing signals rather than being called from them, so no gameplay
	system knows analytics exists and removing this file changes nothing else.

	Every Roblox AnalyticsService call is wrapped: telemetry must never be able to take
	the game down, and these APIs are unavailable in some contexts (older clients, and
	Studio without API access).

	Funnel steps are recorded once per player per session. Repeat firing would inflate
	step counts and make the drop-off between steps meaningless, which is the only
	number this funnel exists to answer.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)

local FUNNEL_NAME = "Onboarding"

local AnalyticsService = {
	Name = "AnalyticsService",
	Priority = 13,
}

local robloxAnalytics: any = nil
local recorded: { [Player]: { [string]: boolean } } = {}

local FUNNEL_STEPS = {
	Joined = 1,
	FirstRep = 2,
	FirstMultiplier = 3,
	FirstKill = 4,
	FirstPurchase = 5,
}

function AnalyticsService:Init()
	-- GetService itself can fail on platforms where the service is absent.
	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	robloxAnalytics = if ok then service else nil
end

local function hasRecorded(player: Player, step: string): boolean
	local seen = recorded[player]
	if seen == nil then
		seen = {}
		recorded[player] = seen
	end

	if seen[step] then
		return true
	end
	seen[step] = true
	return false
end

--[[
	Records a funnel step, at most once per player per session.
]]
function AnalyticsService:LogStep(player: Player, step: string)
	local index = FUNNEL_STEPS[step]
	if index == nil or robloxAnalytics == nil then
		return
	end
	if hasRecorded(player, step) then
		return
	end

	pcall(function()
		robloxAnalytics:LogFunnelStepEvent(player, FUNNEL_NAME, nil, index, step)
	end)
end

--[[
	Records an economy movement. `flow` is "Source" for currency created and "Sink" for
	currency destroyed, which is what makes inflation visible in the dashboards.
]]
function AnalyticsService:LogEconomy(
	player: Player,
	flow: string,
	currency: string,
	amount: number,
	sku: string
)
	if robloxAnalytics == nil or amount <= 0 then
		return
	end

	pcall(function()
		local flowType = if flow == "Source"
			then Enum.AnalyticsEconomyFlowType.Source
			else Enum.AnalyticsEconomyFlowType.Sink

		robloxAnalytics:LogEconomyEvent(player, flowType, currency, amount, 0, sku)
	end)
end

function AnalyticsService:Start()
	local DataService = Loader.Get("DataService")
	local StatService = Loader.Get("StatService")
	local CombatService = Loader.Get("CombatService")
	local TokenService = Loader.Get("TokenService")

	DataService.ProfileLoaded:Connect(function(player: Player)
		self:LogStep(player, "Joined")
	end)

	StatService.StatChanged:Connect(function(player: Player)
		self:LogStep(player, "FirstRep")
	end)

	CombatService.PlayerKilled:Connect(function(_victim: Player, killer: Player)
		self:LogStep(killer, "FirstKill")
	end)

	TokenService.TokensAwarded:Connect(function(player: Player, amount: number)
		self:LogEconomy(player, "Source", "Tokens", amount, "Accrual")
	end)

	-- Rank crossings are the clearest single measure of progression pacing.
	StatService.StatChanged:Connect(function(player: Player)
		local data = DataService:GetData(player)
		if data == nil then
			return
		end

		local rank = RankConfig.Get(StatService:GetTotalPower(player))
		local key = `Rank_{rank.Id}`
		if not hasRecorded(player, key) and robloxAnalytics ~= nil then
			pcall(function()
				robloxAnalytics:LogCustomEvent(player, "RankReached", 1, { rank = rank.Id })
			end)
		end
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		recorded[player] = nil
	end)
end

return AnalyticsService
