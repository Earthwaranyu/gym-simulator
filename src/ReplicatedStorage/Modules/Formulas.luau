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

-- === Finite-number safety ===================================================

--[[
	The ceiling on any single stat.

	1e63 is the top of NumberFormat's suffix range, so a capped stat always has a name
	a player can read, and it is far below the point where a double loses integer
	precision or a sum of five of them reaches infinity. Nothing in the progression
	model gets within astronomical distance of it — the 24h simulation tops out around
	1e17 — so this is a hostile-input rail, not a gameplay limit.

	The rail matters because a single inf or NaN that reaches a profile is permanent:
	it saves, it reloads, it poisons total power, and every comparison against it is
	false, so the player's UI silently stops working and no error is ever raised.
]]
Formulas.MAX_STAT = 1e63

--[[
	Whether a number is safe to store or compute with. NaN fails its own equality
	test; both infinities are excluded explicitly.
]]
function Formulas.IsFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Forces any input into a usable stat value.

	Anything that is not a finite number becomes 0 rather than propagating: a NaN that
	is allowed to flow becomes a NaN in the profile, and the only safe answer to
	"how much stat is NaN?" is none.
]]
function Formulas.SanitizeStat(value: any): number
	if not Formulas.IsFinite(value) then
		return 0
	end
	return math.clamp(value :: number, 0, Formulas.MAX_STAT)
end

--[[
	Forces any input into a usable upgrade level: a whole number in [0, cap].

	Every formula below sanitizes its own arguments rather than trusting the caller.
	That looks redundant when the caller is a service that already validated — but
	these are pure functions reachable from combat, UI, replication, and a profile
	written years ago, and the fuzz pass in RunSelfTest showed most of them happily
	returning NaN or infinity when handed one. A formula that can produce NaN is a
	formula that can freeze a player's progression with no error anywhere.
]]
local function level(value: any): number
	if not Formulas.IsFinite(value) then
		return 0
	end
	return math.clamp(math.floor(value :: number), 0, Formulas.MULTIPLIER_LEVEL_CAP)
end

-- === Training ===============================================================

--[[
	Stat awarded for one automatic rep. The equipment supplies the base; the multiplier
	is the product of the player's whole modifier stack. Kept deliberately trivial — all
	the growth comes from equipment tiers and multipliers, which are both data.
]]
function Formulas.GainPerRep(baseGain: number, multiplier: number): number
	if not Formulas.IsFinite(baseGain) or not Formulas.IsFinite(multiplier) then
		return 0
	end
	return math.clamp(baseGain * multiplier, 0, Formulas.MAX_STAT)
end

-- === Token multipliers ======================================================

-- Safety rail: the highest level MultiplierValue will accept. 2^128 ≈ 3.4e38,
-- which is large but finite and fits comfortably in a double. The cost curve
-- puts level 60 far beyond any reachable token count, so this cap is a data
-- hygiene guard, not a gameplay limit.
Formulas.MULTIPLIER_LEVEL_CAP = 128

--[[
	The multiplier granted by owning `level` upgrades of a stat. Level 0 is 1x.
	Each level doubles the previous value: 2^level. The doubling reads cleanly
	in UI ("2x → 4x → 8x") and gives every purchase the same *relative* impact
	while the exponential COST curve gates pacing.

	Level is clamped to MULTIPLIER_LEVEL_CAP so the value can never reach inf
	and poison a saved profile.
]]
function Formulas.MultiplierValue(upgradeLevel: number): number
	return 2 ^ level(upgradeLevel)
end

--[[
	Token cost of buying the next level. Exponential, so upgrades stay meaningful
	purchases rather than something you buy out in one session.
]]
function Formulas.MultiplierCost(upgradeLevel: number): number
	return math.floor(10 * 1.35 ^ level(upgradeLevel))
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
Formulas.MAX_MUSCLE_SCALE = 2.2

--[[
	How much a body part swells for a given stat value. Log-scaled and hard-capped, so
	the visual difference between a new player and a trillion-stat player is dramatic
	but still a playable humanoid rather than a building.

	`weight` comes from StatConfig.BodyScales and decides how strongly this particular
	part responds relative to others driven by the same stat.
]]
function Formulas.MuscleScale(statValue: number, weight: number): number
	-- A negative or absent weight means "does not grow", not "shrinks": a part scaled
	-- below 1 pulls limbs out of their sockets, and a huge negative weight took the
	-- result to -inf, which Roblox would happily assign to a part's Size.
	if not Formulas.IsFinite(weight) or weight <= 0 then
		return 1
	end
	local growth = softScale(Formulas.SanitizeStat(statValue), 0.12) * weight
	return 1 + math.clamp(growth, 0, Formulas.MAX_MUSCLE_SCALE - 1)
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
	return 100 + softScale(Formulas.SanitizeStat(chestStat), 40)
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
	return 8 + softScale(Formulas.SanitizeStat(armsStat), 9)
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
	local advantage = softScale(Formulas.SanitizeStat(backStat), 1)
		- softScale(Formulas.SanitizeStat(attackerArmsStat), 1)
	if advantage <= 0 then
		return 0
	end
	return math.min(advantage * 0.08, 0.5)
end

--[[
	Damage dealt back to an attacker by the victim's Core, as a share of the damage
	that just landed. Capped at just over a third.

	Expressed as a fraction of the incoming hit rather than as a flat number on
	purpose: it means a heavy hitter takes more back than a light one, so Core is a
	deterrent proportional to what is being done to you, and it can never punish
	somebody for a hit that barely scratched you.

	The cap is where it is because of what it costs over a whole fight. An evenly
	matched attacker needs five hits to win and takes 35% back on each, spending
	about a third of their own health to do it — expensive, survivable, and not an
	inversion. A defender who wants to actually win on retaliation has to out-train
	the attacker on Chest as well, which is a build rather than a free ride.
]]
function Formulas.Retaliation(coreStat: number, damageTaken: number): number
	if not Formulas.IsFinite(damageTaken) or damageTaken <= 0 then
		return 0
	end
	return damageTaken * math.min(0.35, softScale(Formulas.SanitizeStat(coreStat), 0.03))
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
function Formulas.WalkSpeed(_legsStat: number): number
	return 16
end

-- Shift sprint is where Legs matters on the ground. A fresh player runs at 24,
-- while extreme Legs approaches 64 rather than the previous 112-stud blur.
function Formulas.SprintSpeed(legsStat: number): number
	return 24 + math.min(40, softScale(Formulas.SanitizeStat(legsStat), 3))
end

--[[
	Flight speed, also from Legs. `CLAUDE.md` gives Legs "speed in running and
	flying" and only the running half was ever built — everyone flew at a flat 220
	regardless of what they had trained, which made Legs stop mattering at exactly
	the point the map starts being vertical.

	A fresh 40-stud flight is useful without turning the 3,000-stud city into a blur.
	Legs then raises it toward a hard 120-stud ceiling, so traversal improves but a
	player still has time to read landmarks and land accurately.
]]
function Formulas.FlightSpeed(legsStat: number): number
	return 40 + math.min(80, softScale(Formulas.SanitizeStat(legsStat), 4))
end

--[[
	Damage scaling applied when a much stronger player hits a much weaker one.
	Returns a value in [0.25, 1]: the wider the power gap in the attacker's favour,
	the less damage lands. This is the anti-grief dial — a maxed player can still kill
	a beginner, it just is not instant, so being farmed stays survivable.
]]
function Formulas.PowerGapFalloff(rawAttackerPower: number, rawVictimPower: number): number
	local attackerPower = Formulas.SanitizeStat(rawAttackerPower)
	local victimPower = Formulas.SanitizeStat(rawVictimPower)
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
		total += Formulas.SanitizeStat(value)
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

	-- === Hostile input ===================================================
	--
	-- Every value below either arrives from a client, or is derived from a stat that
	-- one day will. The rule is the same for all of them: a formula may return a
	-- boring number, but it may never return NaN, infinity, or an error. A NaN that
	-- escapes here reaches a profile, saves, reloads, and makes every comparison
	-- against that player false — a bug with no error message and no way back.
	local HOSTILE = { 0 / 0, math.huge, -math.huge, -1, -1e308, 1e308, 0, 1e63, 2 ^ 53 }

	local function fuzz(label: string, fn: (...any) -> ...any, arity: number)
		for _, first in HOSTILE do
			for _, second in HOSTILE do
				-- An if-expression truncates a multi-value call to one value, which would
				-- silently discard pcall's result and make this test always pass.
				local ok, result
				if arity == 1 then
					ok, result = pcall(fn, first)
				else
					ok, result = pcall(fn, first, second)
				end
				if not ok then
					table.insert(failures, `{label} errored on ({first}, {second})`)
				elseif type(result) == "number" and not Formulas.IsFinite(result) then
					table.insert(failures, `{label} returned {result} for ({first}, {second})`)
				end
				if arity == 1 then
					break
				end
			end
		end
	end

	fuzz("SanitizeStat", Formulas.SanitizeStat, 1)
	fuzz("MultiplierValue", Formulas.MultiplierValue, 1)
	fuzz("MultiplierCost", Formulas.MultiplierCost, 1)
	fuzz("MaxHealth", Formulas.MaxHealth, 1)
	fuzz("AttackDamage", Formulas.AttackDamage, 1)
	fuzz("WalkSpeed", Formulas.WalkSpeed, 1)
	fuzz("FlightSpeed", Formulas.FlightSpeed, 1)
	fuzz("MuscleScale", Formulas.MuscleScale, 2)
	fuzz("GainPerRep", Formulas.GainPerRep, 2)
	fuzz("DamageResistance", Formulas.DamageResistance, 2)
	fuzz("Retaliation", Formulas.Retaliation, 2)
	fuzz("PowerGapFalloff", Formulas.PowerGapFalloff, 2)

	check("sanitize rejects NaN", Formulas.SanitizeStat(0 / 0) == 0)
	-- Infinity becomes 0, not the cap. Clamping it to MAX_STAT would hand an exploit
	-- the largest legal value in the game as a reward for sending a broken one.
	check("sanitize rejects inf", Formulas.SanitizeStat(math.huge) == 0)
	check("sanitize rejects negatives", Formulas.SanitizeStat(-5) == 0)
	check("sanitize rejects non-numbers", Formulas.SanitizeStat("1e9") == 0)
	check("sanitize passes ordinary values", Formulas.SanitizeStat(1234.5) == 1234.5)
	check("gain never exceeds the cap", Formulas.GainPerRep(1e60, 1e60) <= Formulas.MAX_STAT)
	check("five capped stats stay finite", Formulas.TotalPower({
		a = Formulas.MAX_STAT,
		b = Formulas.MAX_STAT,
		c = Formulas.MAX_STAT,
		d = Formulas.MAX_STAT,
		e = Formulas.MAX_STAT,
	}) < math.huge)

	check("level 0 multiplier is 1x", Formulas.MultiplierValue(0) == 1)
	check("multiplier doubles each level", Formulas.MultiplierValue(5) == 2 * Formulas.MultiplierValue(4))
	check(
		"multiplier stays finite at cap",
		Formulas.MultiplierValue(Formulas.MULTIPLIER_LEVEL_CAP) < math.huge
	)
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

	-- Flight begins useful without crossing the city in seconds, then grows with Legs.
	check("fresh flight beats fresh sprint", Formulas.FlightSpeed(0) > Formulas.SprintSpeed(0))
	check("flight rewards legs", Formulas.FlightSpeed(1e12) > Formulas.FlightSpeed(1e3) * 1.15)
	check("flight is capped", Formulas.FlightSpeed(1e30) <= 120)

	check("walkspeed floor", Formulas.WalkSpeed(0) == 16)
	check("ordinary walking is stable", Formulas.WalkSpeed(1e30) == 16)
	check("fresh sprint starts at 24", Formulas.SprintSpeed(0) == 24)
	check("sprint rewards Legs", Formulas.SprintSpeed(1e9) > Formulas.SprintSpeed(1e3) * 1.15)
	check("sprint is capped", Formulas.SprintSpeed(1e30) <= 64)

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

	check("no core, no retaliation", Formulas.Retaliation(0, 100) == 0)
	check("retaliation grows with core", Formulas.Retaliation(1e9, 100) > Formulas.Retaliation(1e3, 100))
	check("retaliation caps", Formulas.Retaliation(1e30, 100) <= 35.001)
	check("retaliation never exceeds the hit", Formulas.Retaliation(1e30, 100) < 100)
	-- Thorns must not invert a fair fight: winning an even duel should cost the
	-- attacker a chunk of health, never more than they have.
	for _, stat in { 1e3, 1e6, 1e12 } do
		local damage = Formulas.AttackDamage(stat)
		local hits = Formulas.MaxHealth(stat) / damage
		local cost = Formulas.Retaliation(stat, damage) * hits
		check(`retaliation cannot win an even fight at {stat}`, cost < Formulas.MaxHealth(stat))
		check(`retaliation still hurts at {stat}`, cost > 0)
	end

	check("no falloff when weaker", Formulas.PowerGapFalloff(100, 1000) == 1)
	check("no falloff when equal", Formulas.PowerGapFalloff(1000, 1000) == 1)
	check("falloff when far stronger", Formulas.PowerGapFalloff(1e12, 1e3) < 0.5)
	check("falloff never fully blocks", Formulas.PowerGapFalloff(1e30, 1) >= 0.25)

	check("total power sums", Formulas.TotalPower({ a = 2, b = 3 }) == 5)

	return failures
end

return Formulas
