--!strict
--[[
	ReputationService — moves players along the Criminal ↔ Hero axis.

	Listens to CombatService rather than being called by it, so combat has no idea
	reputation exists. Adding another consequence of a kill means another listener,
	not another branch in ApplyDamage.

	The rule is self-balancing: killing a peaceful player drags you toward Criminal,
	and killing a Criminal pushes you toward Hero. Griefers become worth hunting, which
	is what keeps open PvP from being one-directional bullying.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local ReputationConfig = require(ReplicatedStorage.Modules.ReputationConfig)

local DECAY_INTERVAL = 60

local ReputationService = {
	Name = "ReputationService",
	Priority = 25,
}

local DataService: any = nil

-- (player, newReputation, tier)
ReputationService.ReputationChanged = Signal.new()

function ReputationService:Init()
	DataService = Loader.Get("DataService")
end

function ReputationService:Get(player: Player): number
	local data = DataService:GetData(player)
	return if data ~= nil then data.Reputation else 0
end

function ReputationService:GetTier(player: Player): ReputationConfig.ReputationTier
	return ReputationConfig.Get(self:Get(player))
end

--[[
	True when this player is fair game — killing them raises the killer's standing
	rather than lowering it.
]]
function ReputationService:IsOutlaw(player: Player): boolean
	return self:GetTier(player).IsOutlaw
end

--[[
	Applies a reputation change, clamped to the configured range. Announces a tier
	change so the player learns they have crossed a line.
]]
function ReputationService:Add(player: Player, delta: number)
	local data = DataService:GetData(player)
	if data == nil or delta == 0 then
		return
	end

	local before = ReputationConfig.Get(data.Reputation)

	data.Reputation =
		math.clamp(data.Reputation + delta, ReputationConfig.MIN_REPUTATION, ReputationConfig.MAX_REPUTATION)

	DataService:MarkDirty(player)

	local after = ReputationConfig.Get(data.Reputation)
	if after.Id ~= before.Id then
		Net.Event("Notify"):FireClient(player, `You are now {after.DisplayName}.`)
	end

	ReputationService.ReputationChanged:Fire(player, data.Reputation, after)
end

function ReputationService:Start()
	local CombatService = Loader.Get("CombatService")

	CombatService.PlayerKilled:Connect(function(victim: Player, killer: Player, isRepeatKill: boolean)
		-- Repeat kills on the same victim move nothing, or a bounty hunter could farm
		-- one Criminal to Hero, and a griefer could not be punished twice for the same
		-- target either.
		if isRepeatKill then
			return
		end

		-- Judged on what the victim was at the moment of death, so a killer cannot
		-- farm reputation by pushing someone into Criminal first.
		local victimTier = ReputationConfig.Get(self:Get(victim))
		local delta = ReputationConfig.DeltaForKill(self:Get(victim))
		self:Add(killer, delta)

		-- The Info page's "who have you killed" line. Recorded by tier id rather than
		-- as three named counters, so rebanding or renaming a tier in
		-- ReputationConfig stays a one-file change and never needs a migration.
		local data: Types.ProfileData? = DataService:GetData(killer)
		if data ~= nil then
			data.KillsByReputation[victimTier.Id] = (data.KillsByReputation[victimTier.Id] or 0) + 1
			DataService:MarkDirty(killer)
		end
	end)

	-- Drift back toward Neutral, so one bad night does not brand someone forever.
	task.spawn(function()
		while true do
			task.wait(DECAY_INTERVAL)

			for _, player in Players:GetPlayers() do
				local data: Types.ProfileData? = DataService:GetData(player)
				if data == nil or data.Reputation == 0 then
					continue
				end

				local step = math.min(ReputationConfig.DECAY_PER_MINUTE, math.abs(data.Reputation))
				self:Add(player, if data.Reputation > 0 then -step else step)
			end
		end
	end)
end

return ReputationService
