--!strict
--[[
	ReputationConfig — the Criminal → Hero axis, and what moves a player along it.

	The design the user chose is self-balancing: attacking peaceful players drags you
	toward Criminal, and hunting Criminals pushes you toward Hero. Griefers become
	targets, which produces a cops-and-robbers dynamic without any code enforcing one.

	Tiers are a table, so rebanding or renaming them is one edit and never a migration
	— Reputation is stored as a plain signed number on the profile.
]]

export type ReputationTier = {
	Id: string,
	DisplayName: string,
	-- Inclusive lower bound. Entries must stay sorted ascending.
	Min: number,
	Color: Color3,
	-- True for tiers that are fair game: killing one of these raises your standing
	-- instead of lowering it.
	IsOutlaw: boolean,
}

local tiers: { ReputationTier } = {
	{
		Id = "Criminal",
		DisplayName = "Criminal",
		Min = -math.huge,
		Color = Color3.fromRGB(255, 92, 92),
		IsOutlaw = true,
	},
	{
		Id = "Outlaw",
		DisplayName = "Outlaw",
		Min = -60,
		Color = Color3.fromRGB(255, 138, 61),
		IsOutlaw = true,
	},
	{
		Id = "Neutral",
		DisplayName = "Neutral",
		Min = -20,
		Color = Color3.fromRGB(180, 188, 208),
		IsOutlaw = false,
	},
	{
		Id = "Guardian",
		DisplayName = "Guardian",
		Min = 40,
		Color = Color3.fromRGB(102, 187, 106),
		IsOutlaw = false,
	},
	{
		Id = "Hero",
		DisplayName = "Hero",
		Min = 120,
		Color = Color3.fromRGB(126, 231, 255),
		IsOutlaw = false,
	},
}

local ReputationConfig = {}

ReputationConfig.List = tiers

-- Reputation is clamped so a long session cannot put someone permanently out of reach
-- of the opposite tier.
ReputationConfig.MIN_REPUTATION = -200
ReputationConfig.MAX_REPUTATION = 200

-- Killing someone who was not an outlaw.
ReputationConfig.MURDER_PENALTY = -12
-- Killing an outlaw: bounty-hunting is how you climb back.
ReputationConfig.JUSTICE_REWARD = 8
-- Slow drift back toward Neutral, so a one-off grudge kill is not permanent.
ReputationConfig.DECAY_PER_MINUTE = 1

for index = 2, #tiers do
	if tiers[index].Min <= tiers[index - 1].Min then
		error(
			`[ReputationConfig] Tiers must be sorted ascending by Min; "{tiers[index].Id}" breaks the order`
		)
	end
end

--[[
	The tier a reputation score falls in. Never nil — the first entry has no lower bound.
]]
function ReputationConfig.Get(reputation: number): ReputationTier
	for index = #tiers, 1, -1 do
		if reputation >= tiers[index].Min then
			return tiers[index]
		end
	end
	return tiers[1]
end

--[[
	How much killing a victim at this reputation should change the killer's own.
	Positive rewards the kill, negative punishes it.
]]
function ReputationConfig.DeltaForKill(victimReputation: number): number
	if ReputationConfig.Get(victimReputation).IsOutlaw then
		return ReputationConfig.JUSTICE_REWARD
	end
	return ReputationConfig.MURDER_PENALTY
end

return ReputationConfig
