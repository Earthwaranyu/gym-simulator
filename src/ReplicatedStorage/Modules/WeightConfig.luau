--!strict
--[[
	WeightConfig — selectable training loads for each active district.

	Every district begins at zero added load, then offers ten visible increases.
	This makes 0 kg an honest bare-bar/unloaded-machine state and guarantees that
	every tap can add one more authored plate or stack slice.
	The world multiplier still owns the exponential progression; load is a smaller
	within-district effort bonus. Mastering one muscle's final load opens that same
	muscle in the next district; it never opens a different muscle's route.
]]

export type WeightTier = {
	ZoneId: string,
	-- Relevant muscle value needed to enter this district for that muscle.
	RequiredStat: number,
	MinKg: number,
	MaxKg: number,
	StepKg: number,
	-- Relevant muscle stat needed for the heaviest selectable load. Intermediate
	-- steps follow the authored difficulty curve, while the minimum is always usable.
	MaxRequiredStat: number,
}

local tiers: { WeightTier } = {
	{ ZoneId = "Garage", RequiredStat = 0, MinKg = 0, MaxKg = 100, StepKg = 10, MaxRequiredStat = 1e4 },
	{ ZoneId = "Iron", RequiredStat = 1e4, MinKg = 0, MaxKg = 1e3, StepKg = 100, MaxRequiredStat = 50e3 },
	{
		ZoneId = "Powerhouse",
		RequiredStat = 50e3,
		MinKg = 0,
		MaxKg = 10e3,
		StepKg = 1e3,
		MaxRequiredStat = 200e3,
	},
	{
		ZoneId = "Strongman",
		RequiredStat = 200e3,
		MinKg = 0,
		MaxKg = 100e3,
		StepKg = 10e3,
		MaxRequiredStat = 1e6,
	},
	{
		ZoneId = "Titan",
		RequiredStat = 1e6,
		MinKg = 0,
		MaxKg = 1e6,
		StepKg = 100e3,
		MaxRequiredStat = 5e6,
	},
	{
		ZoneId = "Skydeck",
		RequiredStat = 5e6,
		MinKg = 0,
		MaxKg = 10e6,
		StepKg = 1e6,
		MaxRequiredStat = 50e6,
	},
	{
		ZoneId = "Storm",
		RequiredStat = 50e6,
		MinKg = 0,
		MaxKg = 100e6,
		StepKg = 10e6,
		MaxRequiredStat = 500e6,
	},
}

local WeightConfig = {}

-- Kept locally rather than requiring Formulas so this data module remains usable by
-- the bare Luau CLI self-test, where Roblox's `script.Parent` does not exist.
local function finite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function nonNegative(value: any): number
	return if finite(value) then math.max(0, value :: number) else 0
end

WeightConfig.List = tiers
WeightConfig.AUTO_LOAD_PRODUCT_ID = "AutoLoad"
WeightConfig.CHARACTER_WEIGHT_ATTRIBUTE = "TrainingWeightKg"
WeightConfig.CHARACTER_RATIO_ATTRIBUTE = "TrainingWeightRatio"
WeightConfig.STACK_PLATE_KIND = "StackPlate"
-- The selector pin. It rides to whichever plate the load selects and is what makes a
-- split stack read as chosen rather than broken.
WeightConfig.STACK_PIN_KIND = "StackPin"
WeightConfig.FREE_PLATE_KIND = "FreePlate"
WeightConfig.BODY_PLATE_KIND = "BodyPlate"
WeightConfig.VISUAL_KIND_ATTRIBUTE = "LoadVisualKind"
WeightConfig.VISUAL_INDEX_ATTRIBUTE = "LoadVisualIndex"
WeightConfig.VISUAL_COUNT_ATTRIBUTE = "LoadVisualCount"

local byZone: { [string]: WeightTier } = {}
for _, tier in tiers do
	byZone[tier.ZoneId] = tier
end

function WeightConfig.Get(zoneId: string): WeightTier?
	return byZone[zoneId]
end

function WeightConfig.Next(zoneId: string): WeightTier?
	for index, tier in tiers do
		if tier.ZoneId == zoneId then
			return tiers[index + 1]
		end
	end
	return nil
end

function WeightConfig.Ratio(tier: WeightTier, weightKg: number): number
	local span = tier.MaxKg - tier.MinKg
	if span <= 0 then
		return 0
	end
	return math.clamp((weightKg - tier.MinKg) / span, 0, 1)
end

function WeightConfig.ChoiceCount(tier: WeightTier): number
	return math.floor((tier.MaxKg - tier.MinKg) / tier.StepKg + 0.5) + 1
end

-- The lightest load pays the district's advertised rate. The heaviest pays 2x,
-- exactly meeting the next district's minimum: x1×2 hands off to x2×1, and so on.
function WeightConfig.GainMultiplier(tier: WeightTier, weightKg: number): number
	return 1 + WeightConfig.Ratio(tier, weightKg)
end

-- Real repetitions slow as load rises. The heaviest choice takes 45% longer, a
-- readable difference without making the automatic training loop feel stalled.
function WeightConfig.TempoMultiplier(tier: WeightTier, weightKg: number): number
	return 1 + WeightConfig.Ratio(tier, weightKg) * 0.45
end

function WeightConfig.RequiredStat(tier: WeightTier, weightKg: number): number
	local ratio = WeightConfig.Ratio(tier, weightKg)
	local span = tier.MaxRequiredStat - tier.RequiredStat
	return math.floor(tier.RequiredStat + span * ratio ^ 1.65 + 0.5)
end

function WeightConfig.Snap(tier: WeightTier, weightKg: number): number
	if not finite(weightKg) then
		return tier.MinKg
	end
	local steps = math.floor((weightKg - tier.MinKg) / tier.StepKg + 0.5)
	return math.clamp(tier.MinKg + steps * tier.StepKg, tier.MinKg, tier.MaxKg)
end

function WeightConfig.IsSelectable(tier: WeightTier, weightKg: number): boolean
	if not finite(weightKg) or weightKg < tier.MinKg or weightKg > tier.MaxKg then
		return false
	end
	return math.abs(WeightConfig.Snap(tier, weightKg) - weightKg) < 0.001
end

function WeightConfig.Recommended(tier: WeightTier, relevantStat: number): number
	local safeStat = nonNegative(relevantStat)
	if tier.MaxRequiredStat <= 0 then
		return tier.MaxKg
	end
	local statSpan = tier.MaxRequiredStat - tier.RequiredStat
	local ratio = if statSpan > 0
		then math.clamp((safeStat - tier.RequiredStat) / statSpan, 0, 1) ^ (1 / 1.65)
		else 1
	local raw = tier.MinKg + (tier.MaxKg - tier.MinKg) * ratio
	-- Floor to a real choice. Recommendation must never promise a load whose
	-- requirement is a fraction above the player's current stat.
	local steps = math.floor((raw - tier.MinKg) / tier.StepKg + 1e-6)
	return math.clamp(tier.MinKg + steps * tier.StepKg, tier.MinKg, tier.MaxKg)
end

function WeightConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local seen: { [string]: boolean } = {}
	local function check(condition: boolean, message: string)
		if not condition then
			table.insert(failures, message)
		end
	end

	for _, tier in tiers do
		check(not seen[tier.ZoneId], `duplicate tier {tier.ZoneId}`)
		seen[tier.ZoneId] = true
		check(tier.MinKg == 0 and tier.MaxKg > tier.MinKg, `{tier.ZoneId} must begin unloaded`)
		check(tier.RequiredStat >= 0, `{tier.ZoneId} requirement must be non-negative`)
		check(tier.StepKg > 0, `{tier.ZoneId} step must be positive`)
		check(WeightConfig.ChoiceCount(tier) == 11, `{tier.ZoneId} needs bare plus ten loaded states`)
		check(WeightConfig.Recommended(tier, 0) == tier.MinKg, `{tier.ZoneId} zero-stat recommendation`)
		check(
			WeightConfig.Recommended(tier, tier.MaxRequiredStat) == tier.MaxKg,
			`{tier.ZoneId} max-stat recommendation`
		)
		check(WeightConfig.IsSelectable(tier, tier.MinKg), `{tier.ZoneId} minimum must be selectable`)
		check(WeightConfig.IsSelectable(tier, tier.MaxKg), `{tier.ZoneId} maximum must be selectable`)
		check(WeightConfig.GainMultiplier(tier, tier.MinKg) == 1, `{tier.ZoneId} minimum multiplier`)
		check(WeightConfig.GainMultiplier(tier, tier.MaxKg) == 2, `{tier.ZoneId} maximum multiplier`)
		check(WeightConfig.TempoMultiplier(tier, tier.MinKg) == 1, `{tier.ZoneId} minimum tempo`)
		check(WeightConfig.TempoMultiplier(tier, tier.MaxKg) == 1.45, `{tier.ZoneId} maximum tempo`)
	end
	for index = 2, #tiers do
		check(
			tiers[index].RequiredStat == tiers[index - 1].MaxRequiredStat,
			`{tiers[index].ZoneId} must unlock when the previous load is mastered`
		)
	end
	check(WeightConfig.Next(tiers[#tiers].ZoneId) == nil, "final tier must not promise another area")

	return failures
end

return WeightConfig
