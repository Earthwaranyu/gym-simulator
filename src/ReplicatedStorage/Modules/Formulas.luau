--!strict
--[[
	Formulas — every balance number in one place, as pure functions.

	No side effects and no Roblox API, so these can be tuned and self-tested without
	opening Studio (`luau` can run RunSelfTest directly).

	The central problem this file solves: stats climb into the trillions, but PvP has to
	stay playable at every scale. If damage scaled linearly with Arms, a player with 1e12
	would one-shot a player with 1e9 a thousand times over and combat would be decorative.

	So progression and combat use different curves:
	  * Training gains scale MULTIPLICATIVELY, so the numbers keep exploding — that is
	    the dopamine loop, and it is what token multipliers buy.
	  * Combat stats scale LOGARITHMICALLY, so a 1000x stat lead is roughly a 1.3x
	    damage lead. A stronger player reliably wins, but a weaker one can still fight
	    back, and the griefing hook stays fun instead of hopeless.
]]

local Formulas = {}

-- Combat scaling. log10 of the stat, so each 10x of a stat adds a flat step.
local function softScale(value: number, weight: number): number
	if value <= 0 then
		return 0
	end
	return math.log(1 + value, 10) * weight
end

Formulas.SoftScale = softScale

-- === Training ===============================================================

--[[
	Stat awarded for one rep. The equipment supplies the base; the multiplier is the
	product of the player's whole modifier stack. Kept deliberately trivial — all the
	growth comes from equipment tiers and multipliers, which are both data.
]]
function Formulas.GainPerRep(baseGain: number, multiplier: number): number
	return baseGain * multiplier
end

--[[
	Stamina a rep costs. Heavier machines cost more; a bigger Core makes every rep
	slightly cheaper, so Core is worth training even though it is not a damage stat.
]]
function Formulas.StaminaCost(baseCost: number, coreStat: number): number
	local discount = 1 - math.min(0.5, softScale(coreStat, 0.03))
	return baseCost * discount
end

--[[
	Max stamina. Floor of 100 so a fresh player can train immediately.
]]
function Formulas.MaxStamina(coreStat: number): number
	return 100 + softScale(coreStat, 12)
end

--[[
	Stamina regained per second while not training.
]]
function Formulas.StaminaRegen(coreStat: number): number
	return 8 + softScale(coreStat, 1.5)
end

-- === Token multipliers ======================================================

--[[
	The multiplier granted by owning `level` upgrades of a stat. Level 0 is 1x.
	Linear at +25% per level, so the value is predictable while the COST is what
	curves — that reads better in UI than a compounding multiplier.
]]
function Formulas.MultiplierValue(level: number): number
	return 1 + level * 0.25
end

--[[
	Token cost of buying the next level. Exponential, so upgrades stay meaningful
	purchases rather than something you buy out in one session.
]]
function Formulas.MultiplierCost(level: number): number
	return math.floor(10 * 1.35 ^ level)
end

-- === Token accrual ==========================================================

-- Seconds between accrual ticks. Also the granularity a player loses on death.
Formulas.TOKEN_TICK_SECONDS = 15

--[[
	Tokens granted per tick. Flat on purpose: tokens measure time invested, not power,
	so a new player and a veteran earn at the same rate and the upgrade curve alone
	decides pacing.
]]
function Formulas.TokensPerTick(): number
	return 1
end

-- === Combat =================================================================

--[[
	Max health. Core is the tank stat; the log curve means a 1e12 Core player has
	roughly 6x the health of a 1e2 player, not 1e10 times.
]]
function Formulas.MaxHealth(coreStat: number): number
	return 100 + softScale(coreStat, 40)
end

--[[
	Base melee damage before per-ability multipliers. Arms leads, Chest supports.
]]
function Formulas.AttackDamage(armsStat: number, chestStat: number): number
	return 8 + softScale(armsStat, 6) + softScale(chestStat, 3)
end

--[[
	Walkspeed. Capped so Legs cannot turn the gym into a blur, and so a fleeing player
	is always catchable eventually.
]]
function Formulas.WalkSpeed(legsStat: number): number
	return 16 + math.min(14, softScale(legsStat, 1.2))
end

--[[
	Damage scaling applied when a much stronger player hits a much weaker one.
	Returns a value in [0.25, 1]: the wider the power gap in the attacker's favour,
	the less damage lands. This is the anti-grief dial — a maxed player can still kill
	a beginner, it just is not instant, so being farmed stays survivable.
]]
function Formulas.PowerGapFalloff(attackerPower: number, victimPower: number): number
	if attackerPower <= victimPower then
		return 1
	end

	-- Orders of magnitude the attacker is ahead by.
	local decades = math.log(1 + attackerPower, 10) - math.log(1 + victimPower, 10)
	return math.clamp(1 - decades * 0.12, 0.25, 1)
end

--[[
	Total power, the single number shown in the tab bar. Plain sum: it should climb
	visibly with every rep, which a log or average would flatten.
]]
function Formulas.TotalPower(stats: { [string]: number }): number
	local total = 0
	for _, value in stats do
		total += value
	end
	return total
end

-- === Self-test ==============================================================

--[[
	Sanity checks on the curves, not exact values — the point is that the relationships
	hold after retuning, so tweaking a constant does not silently break PvP balance.
]]
function Formulas.RunSelfTest(): { string }
	local failures: { string } = {}

	local function check(label: string, condition: boolean)
		if not condition then
			table.insert(failures, label)
		end
	end

	check("level 0 multiplier is 1x", Formulas.MultiplierValue(0) == 1)
	check("multiplier grows with level", Formulas.MultiplierValue(4) > Formulas.MultiplierValue(3))
	check("multiplier cost grows", Formulas.MultiplierCost(10) > Formulas.MultiplierCost(9))
	check("first upgrade is affordable", Formulas.MultiplierCost(0) <= 10)

	check("health has a floor", Formulas.MaxHealth(0) == 100)
	check("health grows with core", Formulas.MaxHealth(1e12) > Formulas.MaxHealth(1e6))
	-- The whole point of log scaling: a trillion-Core player is tanky, not invincible.
	check("health stays bounded", Formulas.MaxHealth(1e12) < 1000)

	check("damage grows with arms", Formulas.AttackDamage(1e9, 0) > Formulas.AttackDamage(1e3, 0))
	check("damage stays bounded", Formulas.AttackDamage(1e12, 1e12) < 200)

	-- The griefing invariant. Raw damage at 1e12 (~116) does exceed a fresh player's
	-- 100 health, so this only holds once falloff is applied — which is exactly why
	-- CombatService must never skip it.
	local bullyDamage = Formulas.AttackDamage(1e12, 1e12) * Formulas.PowerGapFalloff(3e12, 0)
	check("a maxed player cannot one-shot a beginner", bullyDamage < Formulas.MaxHealth(0))
	check("a maxed player still kills a beginner in a few hits", bullyDamage * 6 > Formulas.MaxHealth(0))

	-- Equal-stat fights should take a similar number of hits at every scale, or combat
	-- gets faster or slower as the server ages.
	local lowTtk = Formulas.MaxHealth(1e3) / Formulas.AttackDamage(1e3, 1e3)
	local highTtk = Formulas.MaxHealth(1e12) / Formulas.AttackDamage(1e12, 1e12)
	check("time-to-kill stays stable across scales", math.abs(lowTtk - highTtk) < 3)

	check("walkspeed floor", Formulas.WalkSpeed(0) == 16)
	check("walkspeed capped", Formulas.WalkSpeed(1e30) <= 30)

	check("no falloff when weaker", Formulas.PowerGapFalloff(100, 1000) == 1)
	check("no falloff when equal", Formulas.PowerGapFalloff(1000, 1000) == 1)
	check("falloff when far stronger", Formulas.PowerGapFalloff(1e12, 1e3) < 0.5)
	check("falloff never fully blocks", Formulas.PowerGapFalloff(1e30, 1) >= 0.25)

	check("stamina floor", Formulas.MaxStamina(0) == 100)
	check("stamina cost discount is capped", Formulas.StaminaCost(10, 1e30) >= 5)

	check("total power sums", Formulas.TotalPower({ a = 2, b = 3 }) == 5)

	return failures
end

return Formulas
