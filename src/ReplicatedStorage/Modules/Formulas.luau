--!strict
--[[
	Formulas — every balance number in one place, as pure functions.

	No side effects and no Roblox API, so these can be tuned and self-tested without
	opening Studio (`luau` can run RunSelfTest directly).

	Training gains scale multiplicatively into enormous numbers, while every formula
	still has to produce a finite Roblox property. Arms and Chest therefore grant direct
	one-for-one bonuses, Back and Core are percentages, and Legs grants one stud/second
	per point until the movement safety caps. Muscle deformation and percentage effects
	remain logarithmic because they must stay useful without becoming physically invalid.
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

-- Built-in character values are separate from muscle bonuses. Exporting these keeps
-- UI copy honest: a player can see "+5 health" and "105 total" without mistaking the
-- avatar's free starting health for five Chest points they did not earn.
Formulas.BASE_HEALTH = 100
Formulas.BASE_ATTACK_DAMAGE = 1
Formulas.BASE_WALK_SPEED = 16
Formulas.BASE_SPRINT_SPEED = 24
Formulas.BASE_FLIGHT_SPEED = 40

-- Percentage defenses must never reach 100%. Full Back resistance would create
-- permanent immunity, while full Core reflection would make attacking equivalent to
-- hitting yourself. Named caps let formulas, tests and UI communicate one rule.
Formulas.MAX_BACK_RESISTANCE = 0.5
Formulas.MAX_CORE_REFLECTION = 0.35

-- Direct velocity scaling has to stop before a Humanoid or flight constraint starts
-- skipping through the map. These are bonus caps, not hidden conversion curves: every
-- Legs point before a cap is exactly +1 stud/second and the Info row shows both bonuses.
Formulas.MAX_SPRINT_BONUS = 40
Formulas.MAX_FLIGHT_BONUS = 80

-- One Chest point is exactly one additional max-health point. The previous log curve
-- made the first Chest point add about twelve health, then made later points add less
-- than one; that is why the visible Chest number and health bar appeared to disagree.
function Formulas.MaxHealth(chestStat: number): number
	return Formulas.BASE_HEALTH + Formulas.SanitizeStat(chestStat)
end

--[[
	Base melee damage before per-ability multipliers. One Arms point is one point of
	additional raw damage, on top of the avatar's small built-in hit. PowerGapFalloff
	then protects a much weaker victim without falsifying the attacker's Arms number.
]]
function Formulas.AttackDamage(armsStat: number): number
	return Formulas.BASE_ATTACK_DAMAGE + Formulas.SanitizeStat(armsStat)
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
	Capped at half, because a stat that could reach immunity is not a stat. Diminishing
	logarithmic growth keeps later Back training useful without ever approaching 100%.
]]
function Formulas.DamageResistance(backStat: number, attackerArmsStat: number): number
	-- Orders of magnitude the defender's Back leads the attacker's Arms by.
	local advantage = softScale(Formulas.SanitizeStat(backStat), 1)
		- softScale(Formulas.SanitizeStat(attackerArmsStat), 1)
	if advantage <= 0 then
		return 0
	end
	return math.min(advantage * 0.08, Formulas.MAX_BACK_RESISTANCE)
end

--[[
	Damage dealt back to an attacker by the victim's Core, as a share of the damage
	that just landed. Capped at just over a third. This separate rate function lets UI
	show the exact percentage without pretending a sample 100-damage hit is the rule.

	Expressed as a fraction of the incoming hit rather than as a flat number on
	purpose: it means a heavy hitter takes more back than a light one, so Core is a
	deterrent proportional to what is being done to you, and it can never punish
	somebody for a hit that barely scratched you.

	The 35% cap means a surviving defender can return a meaningful piece of a hit, but
	never the full hit. A defender who wants to win through retaliation must also invest
	in enough Chest to survive, which makes it a build rather than automatic immunity.
]]
function Formulas.RetaliationRate(coreStat: number): number
	return math.min(Formulas.MAX_CORE_REFLECTION, softScale(Formulas.SanitizeStat(coreStat), 0.03))
end

function Formulas.Retaliation(coreStat: number, damageTaken: number): number
	if not Formulas.IsFinite(damageTaken) or damageTaken <= 0 then
		return 0
	end
	return damageTaken * Formulas.RetaliationRate(coreStat)
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
	return Formulas.BASE_WALK_SPEED
end

-- Shift sprint is where Legs matters on the ground. Every point is +1 stud/second
-- until the established 64-stud safety ceiling.
function Formulas.SprintSpeed(legsStat: number): number
	return Formulas.BASE_SPRINT_SPEED + math.min(Formulas.MAX_SPRINT_BONUS, Formulas.SanitizeStat(legsStat))
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
	return Formulas.BASE_FLIGHT_SPEED + math.min(Formulas.MAX_FLIGHT_BONUS, Formulas.SanitizeStat(legsStat))
end

--[[
	Damage scaling applied when a much stronger player hits a much weaker one.
	Direct Arms damage needs a proportional falloff rather than the old logarithmic
	minimum of 25%, which would let trillion-power players erase beginners instantly.
	The 75-point baseline leaves a fresh victim vulnerable but gives them several hits
	of warning. Equal and weaker attackers still deal their full raw damage.
]]
function Formulas.PowerGapFalloff(rawAttackerPower: number, rawVictimPower: number): number
	local attackerPower = Formulas.SanitizeStat(rawAttackerPower)
	local victimPower = Formulas.SanitizeStat(rawVictimPower)
	if attackerPower <= victimPower then
		return 1
	end

	local protectionBaseline = 75
	return math.clamp((victimPower + protectionBaseline) / (attackerPower + protectionBaseline), 0, 1)
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
	fuzz("RetaliationRate", Formulas.RetaliationRate, 1)
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

	check("health has a 100-point base", Formulas.MaxHealth(0) == Formulas.BASE_HEALTH)
	check("one Chest is one health", Formulas.MaxHealth(1) - Formulas.MaxHealth(0) == 1)
	check("five Chest is five health", Formulas.MaxHealth(5) - Formulas.MaxHealth(0) == 5)
	check("Chest stays one-to-one at scale", Formulas.MaxHealth(1e12) - Formulas.BASE_HEALTH == 1e12)

	check("damage has a 1-point base", Formulas.AttackDamage(0) == Formulas.BASE_ATTACK_DAMAGE)
	check("one Arms is one damage", Formulas.AttackDamage(1) - Formulas.AttackDamage(0) == 1)
	check("five Arms is five damage", Formulas.AttackDamage(5) - Formulas.AttackDamage(0) == 5)
	check("Arms stays one-to-one at scale", Formulas.AttackDamage(1e12) - Formulas.BASE_ATTACK_DAMAGE == 1e12)

	-- The griefing invariant. Direct trillion-scale damage is safe only once the
	-- proportional power-gap falloff is applied.
	local bullyDamage = Formulas.AttackDamage(1e12) * Formulas.PowerGapFalloff(3e12, 0)
	check("a maxed player cannot one-shot a beginner", bullyDamage < Formulas.MaxHealth(0))
	check("a maxed player still kills a beginner in a few hits", bullyDamage * 6 > Formulas.MaxHealth(0))

	-- Equal-stat fights should take a similar number of hits at every scale, or combat
	-- gets faster or slower as the server ages.
	local lowTtk = Formulas.MaxHealth(1e3) / Formulas.AttackDamage(1e3)
	local highTtk = Formulas.MaxHealth(1e12) / Formulas.AttackDamage(1e12)
	check("time-to-kill stays stable across scales", math.abs(lowTtk - highTtk) < 3)

	-- Flight begins useful without crossing the city in seconds. Legs is exactly
	-- one-to-one before each physical velocity cap, and never exceeds that cap.
	check("fresh flight beats fresh sprint", Formulas.FlightSpeed(0) > Formulas.SprintSpeed(0))
	check("one Legs is one flight speed", Formulas.FlightSpeed(1) - Formulas.FlightSpeed(0) == 1)
	check("flight is capped", Formulas.FlightSpeed(1e30) <= 120)

	check("walkspeed floor", Formulas.WalkSpeed(0) == 16)
	check("ordinary walking is stable", Formulas.WalkSpeed(1e30) == 16)
	check("fresh sprint starts at 24", Formulas.SprintSpeed(0) == 24)
	check("one Legs is one sprint speed", Formulas.SprintSpeed(1) - Formulas.SprintSpeed(0) == 1)
	check("sprint is capped", Formulas.SprintSpeed(1e30) <= 64)

	-- Back is a counter to Arms, not a tax on everyone. If equal investment ever
	-- stops cancelling, every balance number above it silently changes meaning.
	check("back does nothing against equal arms", Formulas.DamageResistance(1e9, 1e9) == 0)
	check("back does nothing against stronger arms", Formulas.DamageResistance(1e6, 1e12) == 0)
	check("100 Back is not immunity", Formulas.DamageResistance(100, 0) < Formulas.MAX_BACK_RESISTANCE)
	check("back reduces a weaker attacker", Formulas.DamageResistance(1e12, 1e6) > 0.4)
	check(
		"back grows with the gap",
		Formulas.DamageResistance(1e12, 1e3) > Formulas.DamageResistance(1e12, 1e9)
	)
	check(
		"back never reaches full immunity",
		Formulas.DamageResistance(1e30, 0) <= Formulas.MAX_BACK_RESISTANCE
			and Formulas.MAX_BACK_RESISTANCE < 1
	)
	-- Resistance stacks with falloff, so the two together must still leave a hit
	-- that lands. A defensive build should be expensive to kill, never impossible.
	local vsTank = Formulas.AttackDamage(1e12)
		* Formulas.PowerGapFalloff(1e12, 1e30)
		* (1 - Formulas.DamageResistance(1e30, 1e12))
	check("nothing is immune", vsTank > 0)

	check("no core, no retaliation", Formulas.Retaliation(0, 100) == 0)
	check("100 Core is not full reflection", Formulas.RetaliationRate(100) < Formulas.MAX_CORE_REFLECTION)
	check("retaliation grows with core", Formulas.Retaliation(1e9, 100) > Formulas.Retaliation(1e3, 100))
	check(
		"core never reaches full reflection",
		Formulas.RetaliationRate(1e30) <= Formulas.MAX_CORE_REFLECTION and Formulas.MAX_CORE_REFLECTION < 1
	)
	check(
		"retaliation uses the named cap",
		Formulas.Retaliation(1e30, 100) <= 100 * Formulas.MAX_CORE_REFLECTION
	)
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
	check("falloff never fully blocks", Formulas.PowerGapFalloff(1e30, 1) > 0)

	check("total power sums", Formulas.TotalPower({ a = 2, b = 3 }) == 5)

	return failures
end

return Formulas
