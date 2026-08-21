--!strict
--[[
	ShopConfig — the two supplements, described in one place.

	These used to be bought with cash alongside three other items. Cash is gone; they are
	buyable with Tokens, and with Robux through PurchaseService/Products/. The product
	file owns the Robux transaction, this owns the effect and the token price, and both
	read the same multiplier and duration so they cannot disagree about what a Protein
	Shake is.

	**Prices are stored in minutes, not tokens.** Token income doubles with every physique
	class — TokenService multiplies the tick by MuscleClassConfig's TokenMultiplier — so a
	flat price decays to nothing: a hundred tokens is twenty-five minutes of work to a
	Natural and about three seconds to a Mythic. Storing what an item costs you in *time*
	and deriving the number keeps a Protein Shake the same purchase for the whole game.

	This file deliberately requires nothing. That is what lets it run under the bare luau
	CLI in scripts/selftest.luau, and it is why PriceFor takes the class multiplier rather
	than the class level — the caller looks the multiplier up, and this stays pure.
]]

export type ShopEffect = { Kind: "GlobalBoost", Multiplier: number, Duration: number }

export type ShopItem = {
	Id: string,
	DisplayName: string,
	Description: string,
	-- What this costs, in minutes of token income. See the header.
	PriceMinutes: number,
	Effect: ShopEffect,
}

local items: { ShopItem } = {
	{
		Id = "PreWorkout",
		DisplayName = "Pre-Workout",
		Description = "3x all stats for 3 minutes. Burns fast.",
		PriceMinutes = 11,
		Effect = { Kind = "GlobalBoost", Multiplier = 3, Duration = 180 },
	},
	{
		Id = "ProteinShake",
		DisplayName = "Protein Shake",
		Description = "2x all stats for 10 minutes.",
		PriceMinutes = 15,
		Effect = { Kind = "GlobalBoost", Multiplier = 2, Duration = 600 },
	},
	{
		-- The sustain option. Weaker than either supplement and running longer than both
		-- put together, so the shop is a decision — burn bright before a session, or set
		-- something up and go train — rather than a list where one row is simply best.
		Id = "MealPrep",
		DisplayName = "Meal Prep",
		Description = "1.5x all stats for 45 minutes. Slow and steady.",
		PriceMinutes = 25,
		Effect = { Kind = "GlobalBoost", Multiplier = 1.5, Duration = 2700 },
	},
}

local ShopConfig = {}

ShopConfig.List = items

local byId: { [string]: ShopItem } = {}
for _, item in items do
	if byId[item.Id] ~= nil then
		error(`[ShopConfig] Duplicate shop item id "{item.Id}"`)
	end
	byId[item.Id] = item
end

function ShopConfig.Get(itemId: string): ShopItem?
	return byId[itemId]
end

--[[
	What this item costs a player whose physique class multiplies their income by
	`classMultiplier`.

	Both the server that takes the tokens and the card that quotes the price call this,
	so the shop cannot promise one number and charge another — the same rule
	MobConfig.RewardMultiplier follows for the other direction of the same economy.

	`tokensPerMinute` is passed in rather than imported for the reason in the header:
	this file stays free of requires so it can be self-tested headlessly.
]]
function ShopConfig.PriceFor(item: ShopItem, classMultiplier: number, tokensPerMinute: number): number
	local minutes = if item.PriceMinutes > 0 then item.PriceMinutes else 0
	local multiplier = if classMultiplier > 0 then classMultiplier else 1
	local rate = if tokensPerMinute > 0 then tokensPerMinute else 1
	return math.max(1, math.floor(minutes * rate * multiplier))
end

function ShopConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	local seen: { [string]: boolean } = {}
	for _, item in items do
		check(not seen[item.Id], `duplicate shop item id "{item.Id}"`)
		seen[item.Id] = true
		check(item.PriceMinutes > 0, `{item.Id} costs nothing`)
		check(item.Effect.Multiplier > 1, `{item.Id} boosts nothing`)
		check(item.Effect.Duration > 0, `{item.Id} lasts no time`)
	end

	local sample = items[1]
	local natural = ShopConfig.PriceFor(sample, 1, 4)
	check(natural == sample.PriceMinutes * 4, "a price is its minutes times the rate")
	-- The whole point: income doubles with a class, so the price has to as well, or the
	-- shop stops meaning anything by the middle of the game.
	check(ShopConfig.PriceFor(sample, 2, 4) == natural * 2, "a price doubles when the class multiplier does")
	check(ShopConfig.PriceFor(sample, 512, 4) == natural * 512, "a price scales to the last class")
	check(ShopConfig.PriceFor(sample, 0, 4) == natural, "a nonsense multiplier is treated as Natural")

	return failures
end

return ShopConfig
