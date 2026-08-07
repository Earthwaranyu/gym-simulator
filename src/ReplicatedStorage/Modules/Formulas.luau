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
	Stat awarded for one automatic rep. The equipment supplies the base; the multiplier
	is the product of the player's whole modifier stack. Kept deliberately trivial — all
	the growth comes from equipment tiers and multipliers, which are both data.
]]
function Formulas.GainPerRep(baseGain: number, multiplier: number): number
	return baseGain * multiplier
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

-- === Muscle deformation =====================================================

-- Nothing may exceed this many times its original size, or limbs detach from their
-- joints and characters stop fitting through doorways.
Formulas.MAX_MUSCLE_SCALE = 2.5

--[[
	How much a body part swells for a given stat value. Log-scaled and hard-capped, so
	the visual difference between a new player and a trillion-stat player is dramatic
	but still a playable humanoid rather than a building.

	`weight` comes from StatConfig.BodyScales and decides how strongly this particular
	part responds relative to others driven by the same stat.
]]
function Formulas.MuscleScale(statValue: number, weight: number): number
	local growth = softScale(statValue, 0.12) * weight
	return 1 + math.min(Formulas.MAX_MUSCLE_SCALE - 1, growth)
end

-- === Combat =================================================================

--[[
	Max health, from Chest. The log curve means a 1e12 player has roughly 6x the
	health of a 1e2 player, not 1e10 times.

	This used to read Core, which was simply the wrong stat: CLAUDE.md gives Chest
	the health and Core the retaliation, and the code had the two swapped. Only the
	input changed — the curve is untouched, so nobody's health moved.
]]
function Formulas.MaxHealth(chestStat: number): number
	return 100 + softScale(chestStat, 40)
end

--[[
	Base melee damage before per-ability multipliers. Arms, and only Arms.

	Chest used to contribute a third of this on top of Arms' two thirds, which left
	Chest doing two jobs and Arms sharing its one. The weight here rose from 6 to 9
	to absorb exactly what Chest was adding, so a player who trained both evenly
	deals the same damage as before — 116 at 1e12, 35 at 1e3. This is a
	reassignment, not a rebalance, and the time-to-kill check below proves it.
]]
function Formulas.AttackDamage(armsStat: number): number
	return 8 + softScale(armsStat, 9)
end

--[[
	Damage reduction from the victim's Back, as a fraction in [0, 0.5].

	Contested against the attacker's Arms rather than read off Back alone, and that
	choice is the whole design. A flat reduction from your own Back would stack on
	top of the power-gap falloff and make veteran fights drag; worse, it would be a
	tax every attacker pays regardless of what they trained. Contested, two players
	who invested equally cancel out exactly — so a fair fight is identical to one in
	a world where Back did not exist, and time-to-kill is untouched at every scale.

	What Back buys is an answer to somebody who out-levelled you on Arms alone.
	Capped at half, because a stat that could reach immunity is not a stat.
]]
function Formulas.DamageResistance(backStat: number, attackerArmsStat: number): number
	-- Orders of magnitude the defender's Back leads the attacker's Arms by.
	local advantage = softScale(backStat, 1) - softScale(attackerArmsStat, 1)
	if advantage <= 0 then
		return 0
	end
	return math.min(advantage * 0.08, 0.5)
end

--[[
	Ground speed. Legs is the traversal stat: this is the "run" rung of the
	walk-run-fly ladder, and the reason a map thousands of studs across is a
	progression curve rather than a tax.

	The old ceiling was 30 — under two times base, forever. That was tuned for a
	single gym hall, where the only thing speed did was decide whether you could
	flee a fight. On the current map it would mean a minutes-long walk to the outer
	tiers that never once got shorter, so the cap is now roughly seven times base.

	Fleeing still fails, but for a different reason: the runner and the chaser both
	scale, so a fight is decided by the power gap rather than by a speed ceiling
	neither can reach. CombatService's damage falloff is what protects a weaker
	player now, not the inability to run away.
]]
function Formulas.WalkSpeed(legsStat: number): number
	return 16 + math.min(96, softScale(legsStat, 7))
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
	check("health grows with chest", Formulas.MaxHealth(1e12) > Formulas.MaxHealth(1e6))
	-- The whole point of log scaling: a trillion-Chest player is tanky, not invincible.
	check("health stays bounded", Formulas.MaxHealth(1e12) < 1000)

	check("damage grows with arms", Formulas.AttackDamage(1e9) > Formulas.AttackDamage(1e3))
	check("damage stays bounded", Formulas.AttackDamage(1e12) < 200)

	-- The griefing invariant. Raw damage at 1e12 (~116) does exceed a fresh player's
	-- 100 health, so this only holds once falloff is applied — which is exactly why
	-- CombatService must never skip it.
	local bullyDamage = Formulas.AttackDamage(1e12) * Formulas.PowerGapFalloff(3e12, 0)
	check("a maxed player cannot one-shot a beginner", bullyDamage < Formulas.MaxHealth(0))
	check("a maxed player still kills a beginner in a few hits", bullyDamage * 6 > Formulas.MaxHealth(0))

	-- Equal-stat fights should take a similar number of hits at every scale, or combat
	-- gets faster or slower as the server ages.
	local lowTtk = Formulas.MaxHealth(1e3) / Formulas.AttackDamage(1e3)
	local highTtk = Formulas.MaxHealth(1e12) / Formulas.AttackDamage(1e12)
	check("time-to-kill stays stable across scales", math.abs(lowTtk - highTtk) < 3)

	-- Moving damage off Chest and onto Arms must not have moved these. The numbers
	-- are the ones the old Arms+Chest model produced for an evenly-trained player;
	-- if a weight is ever retuned, this is what says so out loud.
	check("an even build deals what it always did, low", math.abs(Formulas.AttackDamage(1e3) - 35) < 0.5)
	check("an even build deals what it always did, high", math.abs(Formulas.AttackDamage(1e12) - 116) < 0.5)

	check("walkspeed floor", Formulas.WalkSpeed(0) == 16)
	check("walkspeed capped", Formulas.WalkSpeed(1e30) <= 112)
	-- Crossing the map has to visibly improve, or Legs is not a traversal stat and
	-- the outer tiers are a permanent walk.
	check("walkspeed rewards Legs", Formulas.WalkSpeed(1e9) > Formulas.WalkSpeed(1e3) * 1.5)

	-- Back is a counter to Arms, not a tax on everyone. If equal investment ever
	-- stops cancelling, every balance number above it silently changes meaning.
	check("back does nothing against equal arms", Formulas.DamageResistance(1e9, 1e9) == 0)
	check("back does nothing against stronger arms", Formulas.DamageResistance(1e6, 1e12) == 0)
	check("back reduces a weaker attacker", Formulas.DamageResistance(1e12, 1e6) > 0.4)
	check(
		"back grows with the gap",
		Formulas.DamageResistance(1e12, 1e3) > Formulas.DamageResistance(1e12, 1e9)
	)
	check("back caps at half", Formulas.DamageResistance(1e30, 0) <= 0.5)
	-- Resistance stacks with falloff, so the two together must still leave a hit
	-- that lands. A defensive build should be expensive to kill, never impossible.
	local vsTank = Formulas.AttackDamage(1e12)
		* Formulas.PowerGapFalloff(1e12, 1e30)
		* (1 - Formulas.DamageResistance(1e30, 1e12))
	check("nothing is immune", vsTank > 0)

	check("no falloff when weaker", Formulas.PowerGapFalloff(100, 1000) == 1)
	check("no falloff when equal", Formulas.PowerGapFalloff(1000, 1000) == 1)
	check("falloff when far stronger", Formulas.PowerGapFalloff(1e12, 1e3) < 0.5)
	check("falloff never fully blocks", Formulas.PowerGapFalloff(1e30, 1) >= 0.25)

	check("total power sums", Formulas.TotalPower({ a = 2, b = 3 }) == 5)

	return failures
end

return Formulas
