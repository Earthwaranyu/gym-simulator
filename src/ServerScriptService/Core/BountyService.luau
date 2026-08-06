--!strict
--[[
	BountyService — killstreaks put a price on your head.

	This is the comeback path for victims. A player who racks up kills becomes
	progressively more valuable to kill, so the strongest griefer in the server turns
	into the most attractive target rather than an unanswerable problem. Collecting a
	bounty is the one reliable way a weaker player profits from a fight.

	Streaks and bounties are session-only and deliberately not saved: a bounty is a
	live invitation to the players currently in the server, and carrying it across
	rejoins would let someone bank one and log off.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)

-- Cash added to a player's head per kill in their current streak.
local BOUNTY_PER_KILL = 60
-- Streak needed before a bounty is announced to the server.
local ANNOUNCE_AT_STREAK = 3
-- Outlaws are worth more, which is what makes hunting Criminals pay.
local OUTLAW_MULTIPLIER = 1.5

local BountyService = {
	Name = "BountyService",
	Priority = 24,
}

local streaks: { [Player]: number } = {}

local CurrencyService: any = nil
local ReputationService: any = nil

-- (player, streak, bounty)
BountyService.BountyChanged = Signal.new()

function BountyService:Init()
	CurrencyService = Loader.Get("CurrencyService")
	ReputationService = Loader.Get("ReputationService")
end

function BountyService:GetStreak(player: Player): number
	return streaks[player] or 0
end

--[[
	Cash on a player's head right now. Zero until they start a streak.
]]
function BountyService:GetBounty(player: Player): number
	local streak = self:GetStreak(player)
	if streak <= 0 then
		return 0
	end

	local bounty = streak * BOUNTY_PER_KILL
	if ReputationService:IsOutlaw(player) then
		bounty *= OUTLAW_MULTIPLIER
	end

	return math.floor(bounty)
end

function BountyService:_announce(player: Player)
	local bounty = self:GetBounty(player)
	local streak = self:GetStreak(player)

	for _, other in Players:GetPlayers() do
		Net.Event("Notify"):FireClient(other, `{player.Name} is on a {streak} streak — ${bounty} bounty!`)
	end
end

function BountyService:_reset(player: Player)
	if streaks[player] == nil then
		return
	end
	streaks[player] = nil
	BountyService.BountyChanged:Fire(player, 0, 0)
end

function BountyService:Start()
	local CombatService = Loader.Get("CombatService")

	CombatService.PlayerKilled:Connect(function(victim: Player, killer: Player, isRepeatKill: boolean)
		-- Collect the victim's bounty before their streak is cleared. Paid even on a
		-- repeat kill: the bounty was earned by the victim's own streak, so withholding
		-- it would punish the wrong player.
		local bounty = self:GetBounty(victim)
		if bounty > 0 then
			CurrencyService:Add(killer, bounty)
			Net.Event("Notify"):FireClient(killer, `Claimed ${bounty} bounty on {victim.Name}.`)
			Net.Event("Notify"):FireClient(victim, `{killer.Name} claimed your ${bounty} bounty.`)
		end

		self:_reset(victim)

		-- Streaks only grow on fresh targets, so camping one player cannot inflate a
		-- bounty into an infinite cash loop with a friend.
		if isRepeatKill then
			return
		end

		local previous: number = self:GetStreak(killer)
		local streak = previous + 1
		streaks[killer] = streak
		BountyService.BountyChanged:Fire(killer, streak, self:GetBounty(killer))

		if streak >= ANNOUNCE_AT_STREAK then
			self:_announce(killer)
		end
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			-- Dying to anything at all — a fall, the void — clears the streak too.
			self:_reset(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		streaks[player] = nil
	end)
end

return BountyService
