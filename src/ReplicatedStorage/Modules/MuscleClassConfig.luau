--!strict
--[[
	MuscleClassConfig — ten ordered full-body prestige physiques.

	Transforming into the next class requires total Power and costs Fight Tokens. It
	takes no progression away: stats, weights and token multipliers all persist. The
	appearance returns lean in the new class colour and is built again from subsequent
	per-muscle training. Classes cannot be skipped.

	Both numbers on a row double with the class. The cost doubles because everything in
	this economy doubles; the TokenMultiplier doubles because it has to — multiplier
	prices double eighteen times and there are only nine transformations, so prestige is
	the thing that keeps income anywhere near the curve. A class you buy pays for itself
	in playtime, which is what makes spending Fight Tokens on appearance defensible.
]]

export type MuscleClass = {
	Level: number,
	DisplayName: string,
	RequiredPower: number,
	FightTokenCost: number,
	-- Multiplies the playtime Token tick. Doubles with each class, so climbing the
	-- prestige ladder is what keeps income level with multiplier costs that also double.
	TokenMultiplier: number,
	R: number,
	G: number,
	B: number,
}

local classes: { MuscleClass } = {
	{
		Level = 0,
		DisplayName = "Natural",
		RequiredPower = 0,
		FightTokenCost = 0,
		TokenMultiplier = 1,
		R = 170,
		G = 174,
		B = 182,
	},
	{
		Level = 1,
		DisplayName = "Conditioned",
		RequiredPower = 10e3,
		FightTokenCost = 350,
		TokenMultiplier = 2,
		R = 126,
		G = 211,
		B = 155,
	},
	{
		Level = 2,
		DisplayName = "Defined",
		RequiredPower = 100e3,
		FightTokenCost = 650,
		TokenMultiplier = 4,
		R = 84,
		G = 188,
		B = 142,
	},
	{
		Level = 3,
		DisplayName = "Shredded",
		RequiredPower = 1e6,
		FightTokenCost = 1500,
		TokenMultiplier = 8,
		R = 66,
		G = 165,
		B = 245,
	},
	{
		Level = 4,
		DisplayName = "Powerbuilt",
		RequiredPower = 10e6,
		FightTokenCost = 5000,
		TokenMultiplier = 16,
		R = 83,
		G = 118,
		B = 226,
	},
	{
		Level = 5,
		DisplayName = "Elite",
		RequiredPower = 100e6,
		FightTokenCost = 11500,
		TokenMultiplier = 32,
		R = 139,
		G = 92,
		B = 246,
	},
	{
		Level = 6,
		DisplayName = "Beast",
		RequiredPower = 1e9,
		FightTokenCost = 23000,
		TokenMultiplier = 64,
		R = 183,
		G = 81,
		B = 220,
	},
	{
		Level = 7,
		DisplayName = "Monster",
		RequiredPower = 10e9,
		FightTokenCost = 25000,
		TokenMultiplier = 128,
		R = 239,
		G = 92,
		B = 132,
	},
	{
		Level = 8,
		DisplayName = "Titan",
		RequiredPower = 100e9,
		FightTokenCost = 27000,
		TokenMultiplier = 256,
		R = 255,
		G = 155,
		B = 55,
	},
	{
		Level = 9,
		DisplayName = "Mythic",
		RequiredPower = 1e12,
		FightTokenCost = 29000,
		TokenMultiplier = 512,
		R = 255,
		G = 211,
		B = 72,
	},
}

local MuscleClassConfig = {}
MuscleClassConfig.List = classes
MuscleClassConfig.MAX_LEVEL = #classes - 1
local STAT_GROUPS = 5

local function safeLevel(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, MuscleClassConfig.MAX_LEVEL)
end

function MuscleClassConfig.Get(level: number): MuscleClass
	return classes[safeLevel(level) + 1]
end

--[[
	What a Natural-quoted token amount is worth at this class.

	Every token figure in the game is written as what it means to a Natural and scaled
	here: income ticks, mob and quest payouts, and the shop packs. The server grants
	through TokenService:ClassScaled and the shop card quotes the same function, so a
	card cannot promise a number the grant would not credit — and because it lives on
	the config rather than on a service, the client can scale a figure for display
	without a round trip.
]]
function MuscleClassConfig.ScaleTokens(level: number, baseAmount: number): number
	return baseAmount * MuscleClassConfig.Get(level).TokenMultiplier
end

function MuscleClassConfig.Next(level: number): MuscleClass?
	return classes[safeLevel(level) + 2]
end

--[[
	How much one muscle group must gain during this physique to reach its maximum
	visible size.

	The transformation gate uses total Power, so the Power gap is shared evenly across
	the five visual groups. A balanced player reaches full definition everywhere at the
	next gate; a specialist reaches it only on the muscle they actually trained. The
	final class reuses the previous gap because there is no next gate to measure against.
]]
function MuscleClassConfig.VisualStatGoal(level: number): number
	local safe = safeLevel(level)
	local current = MuscleClassConfig.Get(safe)
	local nextClass = MuscleClassConfig.Next(safe)
	if nextClass ~= nil then
		return math.max(1, (nextClass.RequiredPower - current.RequiredPower) / STAT_GROUPS)
	end

	local previous = classes[math.max(1, safe)]
	return math.max(1, (current.RequiredPower - previous.RequiredPower) / STAT_GROUPS)
end

function MuscleClassConfig.Color(level: number): Color3
	local class = MuscleClassConfig.Get(level)
	return Color3.fromRGB(class.R, class.G, class.B)
end

function MuscleClassConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end
	check(#classes == 10, "exactly ten muscle classes")
	for index, class in classes do
		check(class.Level == index - 1, `class {index} level is sequential`)
		if index > 1 then
			check(class.RequiredPower > classes[index - 1].RequiredPower, `class {index} Power rises`)
			--[[
				Cost rises, but no longer doubles.

				It used to, and the assertion here checked exactly that — which was a
				restatement of the table rather than a property worth defending. The
				doubling had never been measured against what fighting actually pays:
				at 5 to 1280 the whole ladder was about two minutes of farming, a
				figure MobConfig's own header had predicted and nobody had checked.

				Prices are now set from `scripts/simulate.luau`'s income model at
				roughly twelve minutes of farming each. They stop doubling because
				income stops doubling — the mob roster ends at Storm while the classes
				run on to a trillion Power — so the top four rise only gently. Rerun
				the simulator after changing any of these; it prints the implied
				minutes per class.
			]]
			check(
				class.FightTokenCost > classes[index - 1].FightTokenCost,
				`class {index} costs more than the one before it`
			)
			check(
				class.TokenMultiplier == classes[index - 1].TokenMultiplier * 2,
				`class {index} token rate doubles`
			)
		else
			check(class.FightTokenCost == 0, "Natural costs no Fight Tokens")
			check(class.TokenMultiplier == 1, "Natural earns the base token rate")
		end
	end
	check(MuscleClassConfig.Next(0) == classes[2], "Natural transforms only to Conditioned")
	check(MuscleClassConfig.Next(MuscleClassConfig.MAX_LEVEL) == nil, "Mythic is final")
	check(MuscleClassConfig.VisualStatGoal(0) == 2000, "Natural fills one muscle over one fifth of its gate")
	check(MuscleClassConfig.VisualStatGoal(1) == 18000, "Conditioned uses the next Power gap")
	check(MuscleClassConfig.VisualStatGoal(9) == 180e9, "final class reuses the last Power gap")
	return failures
end

return MuscleClassConfig
