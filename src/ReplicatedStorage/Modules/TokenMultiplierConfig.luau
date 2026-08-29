--!strict
--[[
	TokenMultiplierConfig — permanent doubling upgrades for each individual muscle.

	Every purchase is gated only by tokens: x1 -> x2 -> x4 -> x8 and onward. Physique
	transformations are a separate Power-reset prestige path and never replace these
	owned levels.
]]

export type MultiplierLevel = {
	Level: number,
	Multiplier: number,
	CostToUnlock: number,
}

local TokenMultiplierConfig = {}

-- Every level costs exactly twice the one before it, because every level is worth
-- exactly twice the one before it. That makes the price per unit of multiplier the
-- same at level 1 and at level 18, so no step is ever a bargain and choosing which
-- muscle to upgrade is a question about what you want to be good at rather than about
-- which step happens to be cheap.
--
-- Written out rather than computed from 100 * 2 ^ (level - 1). The doubling is the
-- rule today, and a single tier can still be nudged here without anyone having to
-- unpick a formula; the self-test below is what keeps the rule honest.
--
-- The array index is the level being unlocked: level 1 is x2, level 18 is x262,144.
-- 26,214,300 tokens takes one muscle all the way.
local COSTS: { number } = {
	100,
	200,
	400,
	800,
	1_600,
	3_200,
	6_400,
	12_800,
	25_600,
	51_200,
	102_400,
	204_800,
	409_600,
	819_200,
	1_638_400,
	3_276_800,
	6_553_600,
	13_107_200,
}

TokenMultiplierConfig.MAX_LEVEL = #COSTS

local function safeLevel(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, TokenMultiplierConfig.MAX_LEVEL)
end

function TokenMultiplierConfig.Get(level: number): MultiplierLevel
	local current = safeLevel(level)
	return {
		Level = current,
		Multiplier = 2 ^ current,
		-- Level 0 is owned by default and therefore has no unlock cost.
		CostToUnlock = if current == 0 then 0 else COSTS[current],
	}
end

function TokenMultiplierConfig.Next(level: number): MultiplierLevel?
	local current = safeLevel(level)
	if current >= TokenMultiplierConfig.MAX_LEVEL then
		return nil
	end
	return TokenMultiplierConfig.Get(current + 1)
end

function TokenMultiplierConfig.Multiplier(level: number): number
	return TokenMultiplierConfig.Get(level).Multiplier
end

function TokenMultiplierConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end
	check(TokenMultiplierConfig.Get(0).Multiplier == 1, "base multiplier is x1")
	local first = TokenMultiplierConfig.Next(0)
	local second = TokenMultiplierConfig.Next(1)
	check(first ~= nil and first.Multiplier == 2, "first purchase changes x1 to x2")
	check(second ~= nil and second.Multiplier == 4, "second purchase changes x2 to x4")
	check(first ~= nil and first.CostToUnlock == 100, "first purchase costs 100 tokens")
	check(second ~= nil and second.CostToUnlock == 200, "second purchase costs 200 tokens")
	check(TokenMultiplierConfig.Get(3).CostToUnlock == 400, "third purchase costs 400 tokens")
	check(TokenMultiplierConfig.Get(18).CostToUnlock == 13_107_200, "final purchase costs 13,107,200 tokens")
	for level = 1, TokenMultiplierConfig.MAX_LEVEL do
		local current = TokenMultiplierConfig.Get(level)
		local previous = TokenMultiplierConfig.Get(level - 1)
		check(current.Multiplier == previous.Multiplier * 2, `level {level} doubles exactly`)
		-- The invariant, not merely "does not decrease": a mistyped digit that left the
		-- ladder rising would pass that weaker check and quietly make one tier a bargain.
		if level > 1 then
			check(
				current.CostToUnlock == previous.CostToUnlock * 2,
				`level {level} costs exactly double level {level - 1}`
			)
		end
	end
	check(TokenMultiplierConfig.Next(TokenMultiplierConfig.MAX_LEVEL) == nil, "safety cap has no next level")
	check(TokenMultiplierConfig.Get(1e9).Multiplier == 262_144, "hostile level clamps to final multiplier")
	return failures
end

return TokenMultiplierConfig
