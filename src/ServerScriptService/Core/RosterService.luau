--!strict
--[[
	RosterService — the public snapshot behind the custom tab bar and the kill feed.

	Broadcasts a whole roster rather than per-player deltas. With a Roblox server cap in
	the dozens, one small table a second is cheaper than tracking which client knows
	what, and it self-heals: a client that misses a push is correct again within a
	second rather than permanently stale.

	Only public information goes over this wire — name, power, rank, reputation tier,
	bounty, kills. Cash, tokens, and purchase history stay on the owner's private
	profile channel.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local ReputationConfig = require(ReplicatedStorage.Modules.ReputationConfig)

local BROADCAST_INTERVAL = 1

local RosterService = {
	Name = "RosterService",
	Priority = 15,
}

local DataService: any = nil
local StatService: any = nil
local ReputationService: any = nil
local BountyService: any = nil
local CombatService: any = nil

function RosterService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	ReputationService = Loader.Get("ReputationService")
	BountyService = Loader.Get("BountyService")
	CombatService = Loader.Get("CombatService")
end

--[[
	Builds the public entry list, strongest first.
]]
function RosterService:Build(): { any }
	local roster = {}

	for _, player in Players:GetPlayers() do
		local data = DataService:GetData(player)
		if data == nil then
			continue
		end

		local power = StatService:GetTotalPower(player)
		local rank = RankConfig.Get(power)
		local tier = ReputationConfig.Get(data.Reputation)

		table.insert(roster, {
			UserId = player.UserId,
			Name = player.DisplayName,
			Power = power,
			RankName = rank.DisplayName,
			RankColor = rank.Color,
			ReputationName = tier.DisplayName,
			ReputationColor = tier.Color,
			IsOutlaw = tier.IsOutlaw,
			Bounty = BountyService:GetBounty(player),
			Streak = BountyService:GetStreak(player),
			Kills = data.Kills,
			Immortal = CombatService:IsImmortal(player),
		})
	end

	table.sort(roster, function(a, b): boolean
		return a.Power > b.Power
	end)

	return roster
end

function RosterService:Broadcast()
	local roster = self:Build()
	Net.Event("RosterChanged"):FireAllClients(roster)
end

function RosterService:Start()
	-- The kill feed is server-wide, unlike CombatFeedback which is per-participant.
	CombatService.PlayerKilled:Connect(function(victim: Player, killer: Player, isRepeatKill: boolean)
		Net.Event("KillFeed"):FireAllClients({
			KillerName = killer.DisplayName,
			VictimName = victim.DisplayName,
			Bounty = 0,
			IsRepeat = isRepeatKill,
			KillerIsOutlaw = ReputationService:IsOutlaw(killer),
		})
		self:Broadcast()
	end)

	Players.PlayerAdded:Connect(function()
		self:Broadcast()
	end)

	Players.PlayerRemoving:Connect(function()
		-- Deferred so the leaving player is already out of GetPlayers().
		task.defer(function()
			self:Broadcast()
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(BROADCAST_INTERVAL)
			self:Broadcast()
		end
	end)
end

return RosterService
