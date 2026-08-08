--!strict
--[[
	StatService — authoritative stat values and the multiplier stack.

	Every stat gain in the game goes through AddStat, and every multiplier goes through
	the stack. The stack has no privileged sources: token upgrades, gamepasses, timed
	supplements, and event buffs are all just modifiers with an id. That is what lets a
	new boost ship without touching this file or the gain formula.

	Stats are stored sparsely — a stat is absent until first earned — so GetStat treats
	missing as zero and adding a sixth stat needs no migration.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local StatService = {
	Name = "StatService",
	-- After DataService, before the systems that award stats.
	Priority = 90,
}

local modifiers: { [Player]: { [string]: Types.Modifier } } = {}
local DataService: any = nil

-- (player, statId, newValue, gained)
StatService.StatChanged = Signal.new()

function StatService:Init()
	DataService = Loader.Get("DataService")
end

function StatService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		modifiers[player] = nil
	end)
end

--[[
	Registers or replaces a multiplier source. Re-calling with the same Id overwrites,
	which is how a source that changes (token levels, a refreshed boost) updates itself.

	Set Multipliers[Types.ALL_STATS] to affect every stat at once.
]]
function StatService:SetModifier(player: Player, modifier: Types.Modifier)
	local playerModifiers = modifiers[player]
	if playerModifiers == nil then
		playerModifiers = {}
		modifiers[player] = playerModifiers
	end
	playerModifiers[modifier.Id] = modifier
end

function StatService:RemoveModifier(player: Player, modifierId: string)
	local playerModifiers = modifiers[player]
	if playerModifiers ~= nil then
		playerModifiers[modifierId] = nil
	end
end

--[[
	The combined multiplier for one stat: the product of every live modifier that
	targets it or targets all stats. Expired modifiers are dropped as they are found,
	so nothing has to sweep them on a timer.
]]
function StatService:GetMultiplier(player: Player, statId: Types.StatId): number
	local playerModifiers = modifiers[player]
	if playerModifiers == nil then
		return 1
	end

	local now = os.time()
	local product = 1

	for modifierId, modifier in playerModifiers do
		if modifier.ExpiresAt ~= nil and modifier.ExpiresAt <= now then
			playerModifiers[modifierId] = nil
			continue
		end

		local everyStat = modifier.Multipliers[Types.ALL_STATS]
		if everyStat ~= nil then
			product *= everyStat
		end

		local thisStat = modifier.Multipliers[statId]
		if thisStat ~= nil then
			product *= thisStat
		end
	end

	return product
end

function StatService:GetStat(player: Player, statId: Types.StatId): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	return data.Stats[statId] or 0
end

--[[
	Awards a stat gain, applying the player's multiplier stack. Returns the amount
	actually gained, which callers use for the floating "+X" popup.

	Rejects unknown stat ids and non-positive amounts rather than erroring, since the
	caller may be acting on client-supplied equipment data.

	Every number that reaches a profile goes through `Formulas.SanitizeStat`. A single
	NaN or infinity that gets saved is permanent: it reloads, it poisons total power,
	and every comparison against it is false, so the player's progression silently
	stops working and nothing ever errors.
]]
function StatService:AddStat(player: Player, statId: Types.StatId, baseAmount: number): number
	if not StatConfig.IsValid(statId) then
		warn(`[StatService] Rejected gain for unknown stat "{statId}"`)
		return 0
	end
	if not Formulas.IsFinite(baseAmount) or baseAmount <= 0 then
		return 0
	end

	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end

	local gained = Formulas.GainPerRep(baseAmount, self:GetMultiplier(player, statId))
	local current = Formulas.SanitizeStat(data.Stats[statId])
	local newValue = Formulas.SanitizeStat(current + gained)

	-- What actually landed, after the cap. A gain that was clipped must not be
	-- reported as if it were paid in full, or the HUD promises what the profile does
	-- not hold.
	gained = newValue - current

	self:_recordIfImpossible(player, statId, gained)

	data.Stats[statId] = newValue

	DataService:MarkDirty(player)
	StatService.StatChanged:Fire(player, statId, newValue, gained)

	return gained
end

--[[
	Notes a gain that no legitimate rep could produce.

	Deliberately does NOT punish. An automated ban on a number is a ban on whatever bug
	produced that number, and the first victims of a false positive are the players who
	found an edge case rather than the ones exploiting it. This records the event and
	leaves the decision to a human looking at a pattern.

	The ceiling is generous on purpose: the strongest legitimate rep in the game is the
	best machine's base gain times the endgame zone multiplier times the multiplier
	stack, and this sits well above that so ordinary endgame play never trips it.
]]
local IMPOSSIBLE_GAIN = 1e30

function StatService:_recordIfImpossible(player: Player, statId: string, gained: number)
	if gained <= IMPOSSIBLE_GAIN then
		return
	end

	warn(`[StatService] Implausible {statId} gain for {player.Name}: {gained}`)

	local AnalyticsService = Loader.Get("AnalyticsService")
	if AnalyticsService ~= nil then
		AnalyticsService:Log(player, "ImplausibleGain", { StatId = statId, Amount = gained })
	end
end

--[[
	The single number shown in the tab bar and used for power-gap falloff.
]]
function StatService:GetTotalPower(player: Player): number
	local data = DataService:GetData(player)
	if data == nil then
		return 0
	end
	-- Sanitized on the way out too. A profile written before these rails existed, or
	-- repaired badly by hand, must not be able to make total power NaN — every
	-- comparison against NaN is false, which silently disables ranks, gates, and the
	-- power-gap falloff all at once.
	local safe: { [string]: number } = {}
	for statId, value in data.Stats do
		safe[statId] = Formulas.SanitizeStat(value)
	end
	return Formulas.TotalPower(safe)
end

return StatService
