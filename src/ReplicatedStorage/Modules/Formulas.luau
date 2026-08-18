--!strict
--[[
	Formulas — every balance number in one place, as pure functions.

	No side effects and no Roblox API, so these can be tuned and self-tested without
	opening Studio (`luau` can run RunSelfTest directly).

	Training gains scale multiplicatively into enormous numbers, while every formula
	still has to produce a finite Roblox property. Arms grants direct damage, Chest grants
	ten health per point, and Back/Core compare their power directly with the attacker's
	Arms using deliberate SPTS-style breakpoints. Legs grants one stud/second per point
	until the movement safety caps. Muscle deformation remains logarithmic because it
	must stay useful without becoming physically invalid.
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

-- === Training ===============================================================

-- Manual training pays one point per second. Machine training is a separate route:
-- its displayed x1 rate is the whole payout, not an invisible +1 stacked beneath it.
Formulas.BASE_TRAINING_PER_SECOND = 1

--[[
	The raw per-second rate while mounted, before player-owned multipliers.

	`equipmentPerSecond` is the machine's normalized rate and `zoneMultiplier` is the
	map tier printed on its pin. Their product is the whole mounted payout: the x1
	starter machine begins at +1/s rather than hiding another manual +1 beneath it.
]]
function Formulas.MachineTrainingRate(equipmentPerSecond: number, zoneMultiplier: number): number
	if not Formulas.IsFinite(equipmentPerSecond) or not Formulas.IsFinite(zoneMultiplier) then
		return 0
	end
	if equipmentPerSecond < 0 or zoneMultiplier < 0 then
		return 0
	end
	return math.clamp(equipmentPerSecond * zoneMultiplier, 0, Formulas.MAX_STAT)
end

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

--[[
	Visible size from progress inside the current physique, where 0 is lean and 1 is
	fully developed. Unlike MuscleScale's lifetime logarithm, this has exact endpoints:
	a transformation can reliably return every part to 1, and no amount of overtraining
	can push it beyond MAX_MUSCLE_SCALE.

	Smoothstep keeps the first few reps subtle, makes the middle of the class visibly
	rewarding, and eases into the cap instead of hitting a visual wall.
]]
function Formulas.MuscleScaleForProgress(progress: number, weight: number): number
	if not Formulas.IsFinite(progress) or not Formulas.IsFinite(weight) or weight <= 0 then
		return 1
	end
	local clamped = math.clamp(progress, 0, 1)
	local shaped = clamped * clamped * (3 - 2 * clamped)
	local growth = (Formulas.MAX_MUSCLE_SCALE - 1) * shaped * weight
	return 1 + math.clamp(growth, 0, Formulas.MAX_MUSCLE_SCALE - 1)
end

-- === Combat =================================================================

-- Built-in character values are separate from muscle bonuses. Exporting these keeps
-- UI copy honest: a player can see "+50 health" and "150 total" without mistaking
-- the avatar's free starting health for five Chest points they did not earn.
Formulas.BASE_HEALTH = 100
-- The smallest punch in the game. A floor rather than a base: it lifts an untrained
-- fist off zero without being added to anybody else's damage, so a trained player's
-- hit is still exactly their Arms. The old `1 + Arms` was a base, and at low Arms it
-- was most of the hit — which is why two fresh players traded 1, 2, 3 and the number
-- read as a counter rather than as their strength.
Formulas.MIN_ATTACK_DAMAGE = 1
Formulas.BASE_WALK_SPEED = 16
Formulas.BASE_SPRINT_SPEED = 24
Formulas.BASE_FLIGHT_SPEED = 40

-- Extreme power gaps intentionally reach complete block/reflection. This is the
-- defining SPTS-style rule: somebody with ten times the relevant defensive stat is
-- not merely a little tougher, but outside the attacker's current combat tier.
Formulas.FULL_DEFENSE_RATIO = 10
Formulas.MAX_BACK_RESISTANCE = 1
Formulas.MAX_CORE_REFLECTION = 1

-- Direct velocity scaling has to stop before a Humanoid or flight constraint starts
-- skipping through the map. These are bonus caps, not hidden conversion curves: every
-- Legs point before a cap is exactly +1 stud/second and the Info row shows both bonuses.
Formulas.MAX_SPRINT_BONUS = 40
Formulas.MAX_FLIGHT_BONUS = 80

-- Flight silhouettes, as fractions of the flier's own top speed rather than as stud
-- counts. Legs raises FlightSpeed toward a 120-stud ceiling, so an absolute threshold
-- would put a fresh player permanently in the hover pose and a maxed one permanently
-- in the cruise. Expressed as fractions, the same three bands mean the same thing to
-- everybody: drifting, travelling, and going as fast as you personally can.
Formulas.FLIGHT_GLIDE_FRACTION = 0.18
Formulas.FLIGHT_CRUISE_FRACTION = 0.65
-- Where the sonic boom fires, and the point speed lines reach full strength.
Formulas.FLIGHT_BOOM_FRACTION = 0.92

-- How far the body may pitch and bank. Both are readability limits, not physics: past
-- roughly these angles a follow camera behind a pitched rig stops reading as flight and
-- starts reading as a fall, which is the exact failure the old upright hold avoided by
-- never tilting at all.
Formulas.MAX_FLIGHT_PITCH_DEGREES = 42
Formulas.MAX_FLIGHT_BANK_DEGREES = 34
-- Turn rate, in radians per second, that earns a full bank. A gentle correction should
-- barely roll the body; only a hard turn should lay it over.
Formulas.FLIGHT_BANK_FULL_TURN_RATE = 2.4

-- Gait. Stride length in studs per full cycle — one cycle is both feet, so a character
-- covering this much ground has taken two steps. Distance-based rather than a fixed
-- cadence, because a cadence that ignored speed is what makes a character look like it
-- is moon-walking when it slows down: the feet keep their rhythm while the body
-- decelerates out from under them.
Formulas.STRIDE_STUDS = 14
-- Both ends clamped. The floor stops a maxed sprinter's legs becoming a blur that reads
-- as a glitch; the ceiling stops somebody creeping forward from stalling mid-step with
-- one foot hanging in the air.
Formulas.MIN_STRIDE_SECONDS = 0.26
Formulas.MAX_STRIDE_SECONDS = 0.9
-- Below this the gait fades out entirely and Roblox's own idle animation plays. Not
-- zero, because a character resting against a wall still reports a few hundredths of a
-- stud per second and a gait that flickered on and off at a standstill is worse than
-- no gait at all.
Formulas.MIN_GAIT_SPEED = 2

-- Forward torso lean, in degrees, at a walk and at a full sprint. A walk leans a little
-- because a heavy character is always slightly ahead of their feet; a sprint leans hard
-- because that is what the silhouette is for.
Formulas.MIN_RUN_LEAN = 4
Formulas.MAX_RUN_LEAN = 18
-- Vertical bob of the whole body, in studs, at a walk and at a sprint. Applied by the
-- controller at twice the stride frequency, because a body rises and falls once per
-- *step* and a stride is two steps.
Formulas.MIN_GAIT_BOB = 0.06
Formulas.MAX_GAIT_BOB = 0.22

-- How hard a landed hit reads, in three bands. Stated by the ability rather than derived
-- from damage, and that is deliberate: for evenly matched players a jab is about two per
-- cent of a health bar, so a damage-relative weight would put all three contacts of a
-- combo in the same band and the combo would not escalate at all. Punch passes rising
-- weights across its three contacts; a heavy passes one.
Formulas.IMPACT_SOLID_WEIGHT = 0.4
Formulas.IMPACT_CRUSHING_WEIGHT = 0.7

-- Field-of-view widening at top speed, in degrees over the camera's resting value.
-- Small on purpose: FOV is the cheapest speed cue there is and also the fastest way to
-- make somebody motion-sick, and it is being applied for minutes at a time rather than
-- for the four frames an impact beat lasts.
Formulas.MAX_FLIGHT_FOV_GAIN = 14

-- Ground Slam's blast. A flat radius with a small Legs bonus: the slam is an Arms
-- move and Legs only decides how far the shock carries. The bonus is deliberately
-- tiny per point and capped early, because a radius that grew with a stat measured
-- in trillions would cover the map by the second hour.
Formulas.BASE_SLAM_RADIUS = 14
Formulas.MAX_SLAM_RADIUS_BONUS = 16
Formulas.SLAM_RADIUS_PER_LEG = 0.05
-- What the slam does at the epicentre, relative to a punch's single contact. Punch
-- splits its damage across three contacts and lands on one target; the slam is one
-- contact on everybody, so the multiplier buys the loss of the combo, not a strictly
-- better move.
Formulas.SLAM_DAMAGE_MULTIPLIER = 2.5
-- Damage at the rim, as a fraction of the epicentre. Standing at the edge of a slam
-- should hurt without being the same hit as standing under it.
Formulas.SLAM_RIM_SHARE = 0.35

-- Hard Punch: one slow, telegraphed contact. Roughly three and a half punches of
-- damage for roughly three punches of cooldown, with the wind-up long enough that a
-- blocking opponent can react to it.
Formulas.HARD_PUNCH_MULTIPLIER = 3.5

-- Knockback, the game's only impact physics. Bounded at both ends: the floor keeps a
-- hit from looking like it missed, and the ceiling keeps a trillion-Arms player from
-- launching somebody out of the world. Between them it follows the same ten-times
-- language the rest of combat uses — an even fight sits halfway up the range, and a
-- tenfold Arms advantage reaches the top.
Formulas.MIN_KNOCKBACK_SPEED = 40
Formulas.MAX_KNOCKBACK_SPEED = 140
-- Fraction of the launch that goes straight up. Purely a readability choice: a purely
-- horizontal shove slides along the floor and reads as a physics glitch, while a hit
-- that pops the victim off the ground reads as force.
Formulas.KNOCKBACK_LIFT = 0.55

-- Active block. Distinct from Back's passive resistance in ResolveDamage: that one is
-- a stat comparison you cannot influence, this one is a button you are holding, and
-- it works against an attacker you have no business surviving. Hence a large floor
-- even when badly outmatched, and a ceiling short of total immunity.
Formulas.BASE_BLOCK_REDUCTION = 0.6
Formulas.MIN_BLOCK_REDUCTION = 0.35
Formulas.MAX_BLOCK_REDUCTION = 0.9
-- One ten-times step of Back over the attacker's Arms is worth this much reduction.
Formulas.BLOCK_REDUCTION_PER_DECADE = 0.15

-- The meter, measured in seconds of held guard. Core is the counter-force stat, so it
-- is what decides how long you can stand there eating hits.
Formulas.BASE_BLOCK_SECONDS = 4
Formulas.MAX_BLOCK_SECONDS_BONUS = 6
Formulas.BLOCK_REGEN_PER_SECOND = 0.6
-- Absorbing a full health bar's worth of damage costs this many seconds of meter, so
-- a block breaks under pressure rather than only under time.
Formulas.BLOCK_DAMAGE_DRAIN_SECONDS = 8
-- Dead time after a break. The punish for holding guard until it shattered.
Formulas.BLOCK_BREAK_PENALTY_SECONDS = 3

-- Ten health per Chest point makes equal Arms/Chest take roughly ten unblocked hits,
-- while a ten-times Arms advantage naturally approaches a one-hit kill.
function Formulas.MaxHealth(chestStat: number): number
	return math.min(Formulas.BASE_HEALTH + Formulas.SanitizeStat(chestStat) * 10, Formulas.MAX_STAT)
end

--[[
	Base melee damage before per-ability multipliers: your Arms, and nothing else.

	Nothing is added on top. The old formula was `1 + Arms`, and at low Arms that one
	point was most of the hit — two fresh players traded 1, then 2, then 3 as Arms
	crept up, and the punch read as a counter ticking rather than as their strength.
	Above the floor, damage is the stat you trained and nothing else.

	The floor exists only so an untrained fist is not a no-op. A brand-new player deals
	1, and from their very first Arms point onward the number they see is their Arms.
]]
function Formulas.AttackDamage(armsStat: number): number
	return math.max(Formulas.SanitizeStat(armsStat), Formulas.MIN_ATTACK_DAMAGE)
end

-- Ratio helper shared by Back and Core. Attack power never drops below one because
-- an untrained punch still deals one damage and dividing by zero would make zero Arms
-- look weaker than the actual hit.
local function defenseRatio(defenseStat: number, attackerArmsStat: number): number
	local defense = Formulas.SanitizeStat(defenseStat)
	local attack = math.max(Formulas.SanitizeStat(attackerArmsStat), Formulas.MIN_ATTACK_DAMAGE)
	return defense / attack
end

Formulas.DefenseRatio = defenseRatio

--[[
	SPTS-style physical resistance mapped onto Back. Equal or lower Back does not alter
	the hit; greater Back blocks 10%, and ten-times Back nullifies it completely.
]]
function Formulas.DamageResistance(backStat: number, attackerArmsStat: number): number
	local ratio = defenseRatio(backStat, attackerArmsStat)
	if ratio >= 10 then
		return 1
	elseif ratio > 1 then
		return 0.1
	end
	return 0
end

--[[
	SPTS-style reflection mapped onto Core. Greater Core returns 10%; ten-times Core
	fully nullifies the direct hit. The original game is closed-source and community
	documentation only promises those two bands, so there are deliberately no invented
	2x/5x tiers here.
]]
function Formulas.ReflectionRate(coreStat: number, attackerArmsStat: number): number
	local ratio = defenseRatio(coreStat, attackerArmsStat)
	if ratio >= 10 then
		return 1
	elseif ratio > 1 then
		return 0.1
	end
	return 0
end

-- Compatibility name for consumers that describe reflection as retaliation.
Formulas.RetaliationRate = Formulas.ReflectionRate

function Formulas.Retaliation(coreStat: number, attackerArmsStat: number, incomingDamage: number): number
	if not Formulas.IsFinite(incomingDamage) or incomingDamage <= 0 then
		return 0
	end
	local rate = Formulas.ReflectionRate(coreStat, attackerArmsStat)
	if rate >= 1 then
		-- Documented SPTS returns the attacker's damage. The Core floor is this game's
		-- explicit extension: it makes a zero-stat player die for punching somebody
		-- whose Core outclasses them, which is the expected power-fantasy result.
		local counterFloor =
			math.min(Formulas.BASE_HEALTH + Formulas.SanitizeStat(coreStat), Formulas.MAX_STAT)
		return math.max(incomingDamage, counterFloor)
	end
	return incomingDamage * rate
end

export type CombatBreakdown = {
	Damage: number,
	Blocked: number,
	Reflected: number,
	BlockRate: number,
	ReflectionRate: number,
}

-- The complete direct-hit order in one pure function: Core splits the raw hit first,
-- then Back blocks a share of what remains. CombatService consumes these exact values
-- and the client displays them, so code, tests and feedback cannot disagree.
function Formulas.ResolveDamage(
	rawDamage: number,
	backStat: number,
	coreStat: number,
	attackerArmsStat: number
): CombatBreakdown
	if not Formulas.IsFinite(rawDamage) or rawDamage <= 0 then
		return { Damage = 0, Blocked = 0, Reflected = 0, BlockRate = 0, ReflectionRate = 0 }
	end

	local reflectionRate = Formulas.ReflectionRate(coreStat, attackerArmsStat)
	local reflected = Formulas.Retaliation(coreStat, attackerArmsStat, rawDamage)
	local afterReflection = rawDamage * (1 - reflectionRate)
	local blockRate = Formulas.DamageResistance(backStat, attackerArmsStat)
	local blocked = afterReflection * blockRate
	return {
		Damage = math.max(0, afterReflection - blocked),
		Blocked = blocked,
		Reflected = reflected,
		BlockRate = blockRate,
		ReflectionRate = reflectionRate,
	}
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
	Ground Slam's blast radius. Legs widens it slightly and then stops mattering.
]]
function Formulas.SlamRadius(legsStat: number): number
	local bonus = Formulas.SanitizeStat(legsStat) * Formulas.SLAM_RADIUS_PER_LEG
	return Formulas.BASE_SLAM_RADIUS + math.min(Formulas.MAX_SLAM_RADIUS_BONUS, bonus)
end

--[[
	Ground Slam's damage at the epicentre, before the victim's own defenses.
]]
function Formulas.SlamDamage(armsStat: number): number
	return math.min(Formulas.AttackDamage(armsStat) * Formulas.SLAM_DAMAGE_MULTIPLIER, Formulas.MAX_STAT)
end

--[[
	How much of the slam reaches somebody `distance` studs from the epicentre.

	Linear from 1 at the centre to SLAM_RIM_SHARE at the rim, and 0 past it. Linear
	rather than inverse-square because the falloff is a gameplay dial the player has to
	be able to feel from where they are standing, not a physical simulation.
]]
function Formulas.SlamFalloff(distance: number, radius: number): number
	if not Formulas.IsFinite(distance) or not Formulas.IsFinite(radius) or radius <= 0 then
		return 0
	end
	local alpha = math.clamp(distance / radius, 0, 1)
	if alpha >= 1 then
		return 0
	end
	return 1 + (Formulas.SLAM_RIM_SHARE - 1) * alpha
end

--[[
	Launch speed of a knockback, in studs per second.

	Reads the Arms-against-Back gap in decades, matching DamageResistance's bands: an
	even fight is the middle of the range and a tenfold advantage is the top of it.
	Both ends are hard-clamped, so this can never be the thing that throws a player
	through the floor.
]]
function Formulas.KnockbackSpeed(attackerArmsStat: number, victimBackStat: number): number
	local attack = math.max(Formulas.SanitizeStat(attackerArmsStat), Formulas.MIN_ATTACK_DAMAGE)
	local defense = math.max(Formulas.SanitizeStat(victimBackStat), 1)
	-- log10 of the ratio: -1 at a tenfold disadvantage, 0 when even, +1 at tenfold.
	local decades = math.clamp(math.log(attack / defense, 10), -1, 1)
	local alpha = (decades + 1) * 0.5
	local span = Formulas.MAX_KNOCKBACK_SPEED - Formulas.MIN_KNOCKBACK_SPEED
	return Formulas.MIN_KNOCKBACK_SPEED + span * alpha
end

--[[
	Fraction of an incoming hit that an active block eats.

	Deliberately generous even when outmatched: a block is a button held at the right
	moment, and a defensive move that stops working exactly when you need it is not a
	move. Back tilts it, but the floor is what makes it worth pressing.
]]
function Formulas.BlockReduction(backStat: number, attackerArmsStat: number): number
	local defense = math.max(Formulas.SanitizeStat(backStat), 1)
	local attack = math.max(Formulas.SanitizeStat(attackerArmsStat), Formulas.MIN_ATTACK_DAMAGE)
	local decades = math.log(defense / attack, 10)
	local reduction = Formulas.BASE_BLOCK_REDUCTION + decades * Formulas.BLOCK_REDUCTION_PER_DECADE
	return math.clamp(reduction, Formulas.MIN_BLOCK_REDUCTION, Formulas.MAX_BLOCK_REDUCTION)
end

--[[
	Block meter capacity, in seconds of held guard. Core is the counter-force stat and
	softScale keeps a trillion-Core player from guarding forever.
]]
function Formulas.BlockMeter(coreStat: number): number
	local bonus = softScale(Formulas.SanitizeStat(coreStat), 0.5)
	return Formulas.BASE_BLOCK_SECONDS + math.min(Formulas.MAX_BLOCK_SECONDS_BONUS, bonus)
end

--[[
	Meter spent absorbing `absorbed` damage against a `maxHealth` health bar.

	Scaled against the victim's own health rather than an absolute number, so a block
	holds for the same number of hits at every point on the progression curve — the
	same reasoning behind the time-to-kill invariant in the self-test.
]]
function Formulas.BlockDrainForAbsorbed(absorbed: number, maxHealth: number): number
	if not Formulas.IsFinite(absorbed) or absorbed <= 0 then
		return 0
	end
	local health = math.max(Formulas.SanitizeStat(maxHealth), 1)
	return math.min(absorbed / health, 1) * Formulas.BLOCK_DAMAGE_DRAIN_SECONDS
end

--[[
	Which flight silhouette a speed belongs to.

	Three bands rather than a continuous blend parameter, because this is also what
	crosses the wire: the client reports a band change and every other client poses the
	flier from it. A float republished as it changed would be a property write to every
	client in the server, every frame, for every player in the air.

	The local flier still blends smoothly — it has its own velocity and never needs the
	attribute — so the coarseness costs nothing to the person actually flying.
]]
function Formulas.FlightBand(speed: number, topSpeed: number): string
	if not Formulas.IsFinite(speed) or not Formulas.IsFinite(topSpeed) or topSpeed <= 0 then
		return "Hover"
	end
	local fraction = math.clamp(speed / topSpeed, 0, 1)
	if fraction >= Formulas.FLIGHT_CRUISE_FRACTION then
		return "Cruise"
	elseif fraction >= Formulas.FLIGHT_GLIDE_FRACTION then
		return "Glide"
	end
	return "Hover"
end

--[[
	How far through the hover-glide-cruise range a speed sits, as 0 to 1.

	Continuous, unlike FlightBand, and used only by the client that owns the flight —
	for the pose blend, the trail width and the field of view, none of which anybody
	else needs to agree with frame by frame.
]]
function Formulas.FlightBlend(speed: number, topSpeed: number): number
	if not Formulas.IsFinite(speed) or not Formulas.IsFinite(topSpeed) or topSpeed <= 0 then
		return 0
	end
	return math.clamp(speed / topSpeed, 0, 1)
end

--[[
	Pitch, in degrees, for a flier climbing or diving at `verticalSpeed`.

	Signed: positive pitches the nose up. Derived from the vertical share of the
	movement rather than from the camera, so a player who is looking down while
	travelling level stays level — the body reports what it is doing, not what the
	player is looking at.
]]
function Formulas.FlightPitch(verticalSpeed: number, speed: number): number
	if not Formulas.IsFinite(verticalSpeed) or not Formulas.IsFinite(speed) or speed <= 1e-3 then
		return 0
	end
	local share = math.clamp(verticalSpeed / speed, -1, 1)
	return share * Formulas.MAX_FLIGHT_PITCH_DEGREES
end

--[[
	Bank, in degrees, for a flier turning at `turnRate` radians per second.

	Signed, and rolls into the turn: a left turn drops the left shoulder. Linear up to
	FLIGHT_BANK_FULL_TURN_RATE and clamped past it, so a twitchy camera cannot spin the
	body faster than the eye can follow.
]]
function Formulas.FlightBank(turnRate: number): number
	if not Formulas.IsFinite(turnRate) then
		return 0
	end
	local share = math.clamp(turnRate / Formulas.FLIGHT_BANK_FULL_TURN_RATE, -1, 1)
	return share * Formulas.MAX_FLIGHT_BANK_DEGREES
end

--[[
	Extra field of view, in degrees, at a given fraction of top speed.

	Quadratic rather than linear so the widening is imperceptible while manoeuvring and
	only really arrives at the top of the range, where it is the difference between fast
	and very fast.
]]
function Formulas.FlightFovGain(blend: number): number
	if not Formulas.IsFinite(blend) then
		return 0
	end
	local t = math.clamp(blend, 0, 1)
	return t * t * Formulas.MAX_FLIGHT_FOV_GAIN
end

--[[
	Seconds for one full stride cycle — both feet — at a given ground speed.

	Derived from distance rather than from a cadence table: the stride covers a fixed
	length of ground, so going faster takes the same steps sooner rather than taking
	different steps. That is the property that keeps the feet planted-looking when a
	character accelerates or slows, and it is why the gait controller advances its phase
	by distance covered rather than by wall clock.
]]
function Formulas.StrideInterval(speed: number): number
	if not Formulas.IsFinite(speed) or speed <= 0 then
		return Formulas.MAX_STRIDE_SECONDS
	end
	return math.clamp(Formulas.STRIDE_STUDS / speed, Formulas.MIN_STRIDE_SECONDS, Formulas.MAX_STRIDE_SECONDS)
end

--[[
	How far between a walk and a sprint a speed sits, as 0 to 1.

	Taken against this character's own walk and sprint speeds rather than against
	absolute numbers, so a fresh player and one with forty Legs both reach the full
	sprint silhouette when they are running as fast as they personally can. The same
	reasoning as FlightBand's fractions.
]]
function Formulas.GaitBlend(speed: number, walkSpeed: number, sprintSpeed: number): number
	if
		not Formulas.IsFinite(speed)
		or not Formulas.IsFinite(walkSpeed)
		or not Formulas.IsFinite(sprintSpeed)
	then
		return 0
	end
	local span = sprintSpeed - walkSpeed
	if span <= 1e-3 then
		return 0
	end
	return math.clamp((speed - walkSpeed) / span, 0, 1)
end

--[[
	Forward torso lean, in degrees, for a gait blend of 0 to 1.
]]
function Formulas.RunLean(blend: number): number
	if not Formulas.IsFinite(blend) then
		return Formulas.MIN_RUN_LEAN
	end
	local t = math.clamp(blend, 0, 1)
	return Formulas.MIN_RUN_LEAN + (Formulas.MAX_RUN_LEAN - Formulas.MIN_RUN_LEAN) * t
end

--[[
	Vertical bob amplitude, in studs, for a gait blend of 0 to 1.
]]
function Formulas.GaitBob(blend: number): number
	if not Formulas.IsFinite(blend) then
		return Formulas.MIN_GAIT_BOB
	end
	local t = math.clamp(blend, 0, 1)
	return Formulas.MIN_GAIT_BOB + (Formulas.MAX_GAIT_BOB - Formulas.MIN_GAIT_BOB) * t
end

--[[
	Which of the three impact bands a hit belongs to.

	Bands rather than a continuous scale because the effects differ in *kind* and not
	only in size — a light hit has no camera shake at all, a crushing one has a hit-stop
	and an impact frame — and "does this hit shake the screen" is not a thing to
	interpolate. Kept here rather than as comparisons inside the effect controller so the
	thresholds are one place.
]]
function Formulas.ImpactTier(weight: number): string
	if not Formulas.IsFinite(weight) then
		return "Light"
	end
	if weight >= Formulas.IMPACT_CRUSHING_WEIGHT then
		return "Crushing"
	elseif weight >= Formulas.IMPACT_SOLID_WEIGHT then
		return "Solid"
	end
	return "Light"
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
				elseif arity == 2 then
					ok, result = pcall(fn, first, second)
				else
					ok, result = pcall(fn, first, second, first)
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
	fuzz("MaxHealth", Formulas.MaxHealth, 1)
	fuzz("AttackDamage", Formulas.AttackDamage, 1)
	fuzz("WalkSpeed", Formulas.WalkSpeed, 1)
	fuzz("FlightSpeed", Formulas.FlightSpeed, 1)
	fuzz("MuscleScale", Formulas.MuscleScale, 2)
	fuzz("MuscleScaleForProgress", Formulas.MuscleScaleForProgress, 2)
	fuzz("GainPerRep", Formulas.GainPerRep, 2)
	fuzz("MachineTrainingRate", Formulas.MachineTrainingRate, 2)
	fuzz("DamageResistance", Formulas.DamageResistance, 2)
	fuzz("ReflectionRate", Formulas.ReflectionRate, 2)
	fuzz("Retaliation", Formulas.Retaliation, 3)

	check("sanitize rejects NaN", Formulas.SanitizeStat(0 / 0) == 0)
	-- Infinity becomes 0, not the cap. Clamping it to MAX_STAT would hand an exploit
	-- the largest legal value in the game as a reward for sending a broken one.
	check("sanitize rejects inf", Formulas.SanitizeStat(math.huge) == 0)
	check("sanitize rejects negatives", Formulas.SanitizeStat(-5) == 0)
	check("sanitize rejects non-numbers", Formulas.SanitizeStat("1e9") == 0)
	check("sanitize passes ordinary values", Formulas.SanitizeStat(1234.5) == 1234.5)
	check("gain never exceeds the cap", Formulas.GainPerRep(1e60, 1e60) <= Formulas.MAX_STAT)
	check("manual training starts at one per second", Formulas.BASE_TRAINING_PER_SECOND == 1)
	check("x1 machine pays exactly one", Formulas.MachineTrainingRate(1, 1) == 1)
	check("x4 machine pays exactly four", Formulas.MachineTrainingRate(1, 4) == 4)
	check("five capped stats stay finite", Formulas.TotalPower({
		a = Formulas.MAX_STAT,
		b = Formulas.MAX_STAT,
		c = Formulas.MAX_STAT,
		d = Formulas.MAX_STAT,
		e = Formulas.MAX_STAT,
	}) < math.huge)
	check("fresh physique is visually lean", Formulas.MuscleScaleForProgress(0, 1) == 1)
	check(
		"full physique reaches the visual cap",
		Formulas.MuscleScaleForProgress(1, 1) == Formulas.MAX_MUSCLE_SCALE
	)
	check(
		"overtraining cannot exceed the visual cap",
		Formulas.MuscleScaleForProgress(99, 1) == Formulas.MAX_MUSCLE_SCALE
	)

	check("health has a 100-point base", Formulas.MaxHealth(0) == Formulas.BASE_HEALTH)
	check("one Chest is ten health", Formulas.MaxHealth(1) - Formulas.MaxHealth(0) == 10)
	check("five Chest is fifty health", Formulas.MaxHealth(5) - Formulas.MaxHealth(0) == 50)
	check("Chest stays ten-to-one at scale", Formulas.MaxHealth(1e12) - Formulas.BASE_HEALTH == 1e13)

	-- The floor lifts an untrained punch off zero and touches nothing else: from one
	-- Arms upward the damage IS the stat, with nothing added. Written as absolute
	-- values rather than differences precisely so a base creeping back in would fail.
	check("an untrained punch still lands", Formulas.AttackDamage(0) == Formulas.MIN_ATTACK_DAMAGE)
	check("one Arms is one damage", Formulas.AttackDamage(1) == 1)
	check("five Arms is five damage", Formulas.AttackDamage(5) == 5)
	check("Arms stays one-to-one at scale", Formulas.AttackDamage(1e12) == 1e12)
	check("nothing is added on top of Arms", Formulas.AttackDamage(1e12) == 1e12)

	-- There is deliberately no griefing invariant here any more. Damage used to pass
	-- through a power-gap falloff so a maxed player could not one-shot a beginner;
	-- that was removed on purpose, in favour of a punch always dealing exactly the
	-- strength the attacker trained. A maxed player now kills a fresh one instantly,
	-- and the safe zone and the immortality potions are what a beginner has instead.

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

	-- Documented SPTS bands. Boundary tests keep a future tune from accidentally
	-- turning the two readable thresholds back into an invented smooth curve.
	check("lower back blocks nothing", Formulas.DamageResistance(999, 1000) == 0)
	check("equal back blocks nothing", Formulas.DamageResistance(1000, 1000) == 0)
	check("greater back blocks ten percent", Formulas.DamageResistance(1001, 1000) == 0.1)
	check("nine-times back still blocks ten percent", Formulas.DamageResistance(9999, 1000) == 0.1)
	check("ten-times back fully blocks", Formulas.DamageResistance(10000, 1000) == 1)

	check("core below equal reflects nothing", Formulas.ReflectionRate(999, 1000) == 0)
	check("equal core reflects nothing", Formulas.ReflectionRate(1000, 1000) == 0)
	check("greater core reflects ten percent", Formulas.ReflectionRate(1001, 1000) == 0.1)
	check("nine-times core still reflects ten percent", Formulas.ReflectionRate(9999, 1000) == 0.1)
	check("ten-times core fully reflects", Formulas.ReflectionRate(10000, 1000) == 1)
	check("no core, no retaliation", Formulas.Retaliation(0, 1000, 100) == 0)
	check("partial retaliation returns ten percent", Formulas.Retaliation(2000, 1000, 100) == 10)
	check("full retaliation uses the Core counter floor", Formulas.Retaliation(10000, 1000, 100) == 10100)
	local equalFight = Formulas.ResolveDamage(1000, 1000, 1000, 1000)
	check("equal fight does not reflect", equalFight.Reflected == 0)
	check("equal fight does not block", equalFight.Blocked == 0)
	check("equal fight lands raw damage", equalFight.Damage == 1000)
	local partialDefense = Formulas.ResolveDamage(1000, 2000, 2000, 1000)
	check("partial defense reflects ten percent first", partialDefense.Reflected == 100)
	check("partial defense blocks ten percent of the remainder", partialDefense.Blocked == 90)
	check("partial defense lands eighty-one percent", partialDefense.Damage == 810)
	local fullCore = Formulas.ResolveDamage(1000, 1e30, 10000, 1000)
	check("full reflection leaves nothing for Back", fullCore.Reflected == 10100 and fullCore.Blocked == 0)
	check("full reflection deals no direct damage", fullCore.Damage == 0)
	local zeroAttacker = Formulas.ResolveDamage(1, 200, 200, 0)
	check("zero-power attacker receives a lethal Core counter", zeroAttacker.Reflected == 300)
	check("zero-power punch cannot hurt the stronger defender", zeroAttacker.Damage == 0)
	local fullBack = Formulas.ResolveDamage(1000, 10000, 0, 1000)
	check("full Back blocks the whole unreflected hit", fullBack.Blocked == 1000 and fullBack.Damage == 0)
	check("invalid raw damage resolves safely", Formulas.ResolveDamage(0 / 0, 1, 1, 1).Damage == 0)

	-- Ability curves. The slam and the heavy are both meant to beat a single punch
	-- contact and lose to a full punch combo, which is what makes them cooldown moves
	-- rather than strictly better attacks.
	check("slam beats one punch contact", Formulas.SlamDamage(1000) > Formulas.AttackDamage(1000))
	check("slam scales with Arms", Formulas.SlamDamage(1e12) / Formulas.SlamDamage(1e6) == 1e6)
	check("slam radius has a floor", Formulas.SlamRadius(0) == Formulas.BASE_SLAM_RADIUS)
	check(
		"slam radius is capped",
		Formulas.SlamRadius(1e30) <= Formulas.BASE_SLAM_RADIUS + Formulas.MAX_SLAM_RADIUS_BONUS
	)
	check("slam is full strength at the epicentre", Formulas.SlamFalloff(0, 20) == 1)
	check("slam misses past the rim", Formulas.SlamFalloff(21, 20) == 0)
	check("slam is weakest at the rim", Formulas.SlamFalloff(19.99, 20) < 0.4)
	check("slam falloff never inverts", Formulas.SlamFalloff(5, 20) > Formulas.SlamFalloff(15, 20))
	check("slam falloff survives bad input", Formulas.SlamFalloff(0 / 0, 20) == 0)

	-- Knockback is bounded at both ends at every scale. This is the invariant that
	-- keeps a maxed player from launching somebody out of the world.
	check("even fight knocks back mid-range", math.abs(Formulas.KnockbackSpeed(1000, 1000) - 90) < 1e-6)
	check(
		"stronger arms knock back harder",
		Formulas.KnockbackSpeed(10000, 1000) > Formulas.KnockbackSpeed(1000, 1000)
	)
	check("knockback is capped", Formulas.KnockbackSpeed(1e30, 1) == Formulas.MAX_KNOCKBACK_SPEED)
	check("knockback has a floor", Formulas.KnockbackSpeed(1, 1e30) == Formulas.MIN_KNOCKBACK_SPEED)

	-- An active block always does something, and never everything.
	check(
		"even block eats the base share",
		math.abs(Formulas.BlockReduction(1000, 1000) - Formulas.BASE_BLOCK_REDUCTION) < 1e-6
	)
	check(
		"block still works when outmatched",
		Formulas.BlockReduction(1, 1e30) >= Formulas.MIN_BLOCK_REDUCTION
	)
	check("block is never total immunity", Formulas.BlockReduction(1e30, 1) <= Formulas.MAX_BLOCK_REDUCTION)
	check("more back blocks more", Formulas.BlockReduction(10000, 1000) > Formulas.BlockReduction(1000, 1000))

	check("fresh block holds for the base seconds", Formulas.BlockMeter(0) == Formulas.BASE_BLOCK_SECONDS)
	check("core lengthens the guard", Formulas.BlockMeter(1e6) > Formulas.BlockMeter(0))
	check(
		"guard length is capped",
		Formulas.BlockMeter(1e30) <= Formulas.BASE_BLOCK_SECONDS + Formulas.MAX_BLOCK_SECONDS_BONUS
	)
	-- Absorbing costs the same share of the meter at every scale, so a guard survives
	-- the same number of hits for a fresh player and a maxed one.
	local freshDrain = Formulas.BlockDrainForAbsorbed(Formulas.MaxHealth(10) * 0.25, Formulas.MaxHealth(10))
	local maxedDrain =
		Formulas.BlockDrainForAbsorbed(Formulas.MaxHealth(1e12) * 0.25, Formulas.MaxHealth(1e12))
	check("block drain is scale-free", math.abs(freshDrain - maxedDrain) < 1e-6)
	check(
		"one full bar empties the guard",
		Formulas.BlockDrainForAbsorbed(100, 100) == Formulas.BLOCK_DAMAGE_DRAIN_SECONDS
	)
	check("no damage costs no meter", Formulas.BlockDrainForAbsorbed(0, 100) == 0)
	check("block drain survives bad input", Formulas.BlockDrainForAbsorbed(0 / 0, 100) == 0)

	-- Flight bands are fractions of the flier's own top speed, so the same three
	-- silhouettes mean the same thing to a fresh player and a maxed one. This is the
	-- invariant that stops a beginner being stuck in the hover pose forever.
	local freshTop = Formulas.FlightSpeed(0)
	local maxedTop = Formulas.FlightSpeed(1e12)
	check("a still flier hovers", Formulas.FlightBand(0, freshTop) == "Hover")
	check("full speed is a cruise", Formulas.FlightBand(freshTop, freshTop) == "Cruise")
	check(
		"the bands are scale-free",
		Formulas.FlightBand(freshTop * 0.4, freshTop) == Formulas.FlightBand(maxedTop * 0.4, maxedTop)
	)
	check("half speed is a glide", Formulas.FlightBand(freshTop * 0.4, freshTop) == "Glide")
	check("bands survive a zero top speed", Formulas.FlightBand(10, 0) == "Hover")
	check("bands survive bad input", Formulas.FlightBand(0 / 0, freshTop) == "Hover")
	check(
		"the glide band opens before the cruise band",
		Formulas.FLIGHT_GLIDE_FRACTION < Formulas.FLIGHT_CRUISE_FRACTION
			and Formulas.FLIGHT_CRUISE_FRACTION < Formulas.FLIGHT_BOOM_FRACTION
	)

	check("blend is zero at rest", Formulas.FlightBlend(0, freshTop) == 0)
	check("blend saturates at top speed", Formulas.FlightBlend(freshTop * 2, freshTop) == 1)
	check("blend survives bad input", Formulas.FlightBlend(0 / 0, freshTop) == 0)

	-- Pitch and bank are signed and bounded. The bounds are the whole reason the body
	-- can be tilted at all: past them a follow camera reads a pitched rig as falling.
	check("level flight does not pitch", Formulas.FlightPitch(0, 100) == 0)
	check("climbing pitches up", Formulas.FlightPitch(50, 100) > 0)
	check("diving pitches down", Formulas.FlightPitch(-50, 100) < 0)
	check("pitch is capped", math.abs(Formulas.FlightPitch(1e6, 1e6)) <= Formulas.MAX_FLIGHT_PITCH_DEGREES)
	check("pitch survives a standstill", Formulas.FlightPitch(10, 0) == 0)

	check("flying straight does not bank", Formulas.FlightBank(0) == 0)
	check("turning banks into the turn", Formulas.FlightBank(1) > 0)
	check("banking is signed", Formulas.FlightBank(-1) == -Formulas.FlightBank(1))
	check("bank is capped", math.abs(Formulas.FlightBank(1e6)) <= Formulas.MAX_FLIGHT_BANK_DEGREES)
	check("bank survives bad input", Formulas.FlightBank(0 / 0) == 0)

	-- Field of view is held for minutes rather than for the four frames an impact beat
	-- lasts, so it stays small and arrives late.
	check("hovering does not widen the view", Formulas.FlightFovGain(0) == 0)
	check("top speed widens it fully", Formulas.FlightFovGain(1) == Formulas.MAX_FLIGHT_FOV_GAIN)
	check("the widening arrives late", Formulas.FlightFovGain(0.5) < Formulas.MAX_FLIGHT_FOV_GAIN * 0.5)
	check("fov gain is capped", Formulas.FlightFovGain(9) == Formulas.MAX_FLIGHT_FOV_GAIN)

	-- The stride covers ground rather than keeping a cadence. Going twice as fast has
	-- to take the same steps twice as often, or the feet slide: this is the invariant
	-- that stops a decelerating character moon-walking.
	check(
		"twice the speed is half the stride time",
		math.abs(Formulas.StrideInterval(20) - Formulas.StrideInterval(40) * 2) < 1e-6
	)
	check("faster is never slower to step", Formulas.StrideInterval(40) < Formulas.StrideInterval(20))
	check("stride time has a floor", Formulas.StrideInterval(1e9) == Formulas.MIN_STRIDE_SECONDS)
	check("stride time has a ceiling", Formulas.StrideInterval(0.001) == Formulas.MAX_STRIDE_SECONDS)
	check("a standstill does not divide by zero", Formulas.StrideInterval(0) == Formulas.MAX_STRIDE_SECONDS)
	check("stride time survives bad input", Formulas.StrideInterval(0 / 0) == Formulas.MAX_STRIDE_SECONDS)

	-- The blend is taken against this character's own speeds, so everybody reaches the
	-- sprint silhouette at their own top speed rather than at an absolute number a
	-- fresh player could never reach.
	local freshWalk, freshSprint = Formulas.WalkSpeed(0), Formulas.SprintSpeed(0)
	local fastWalk, fastSprint = Formulas.WalkSpeed(40), Formulas.SprintSpeed(40)
	check("walking is not a sprint", Formulas.GaitBlend(freshWalk, freshWalk, freshSprint) == 0)
	check("sprinting is a full sprint", Formulas.GaitBlend(freshSprint, freshWalk, freshSprint) == 1)
	check(
		"the blend is scale-free",
		Formulas.GaitBlend((freshWalk + freshSprint) / 2, freshWalk, freshSprint)
			== Formulas.GaitBlend((fastWalk + fastSprint) / 2, fastWalk, fastSprint)
	)
	check("standing still is not a sprint", Formulas.GaitBlend(0, freshWalk, freshSprint) == 0)
	check("overspeed is clamped", Formulas.GaitBlend(1e6, freshWalk, freshSprint) == 1)
	check("a zero span does not divide by zero", Formulas.GaitBlend(20, 16, 16) == 0)
	check("gait blend survives bad input", Formulas.GaitBlend(0 / 0, 16, 24) == 0)

	-- Lean and bob both grow with the blend and are bounded at both ends.
	check("a walk already leans a little", Formulas.RunLean(0) == Formulas.MIN_RUN_LEAN)
	check("a sprint leans hardest", Formulas.RunLean(1) == Formulas.MAX_RUN_LEAN)
	check("lean is capped", Formulas.RunLean(9) == Formulas.MAX_RUN_LEAN)
	check("lean grows with speed", Formulas.RunLean(0.6) > Formulas.RunLean(0.2))
	check("bob grows with speed", Formulas.GaitBob(1) > Formulas.GaitBob(0))
	check("bob is capped", Formulas.GaitBob(9) == Formulas.MAX_GAIT_BOB)
	check("bob survives bad input", Formulas.GaitBob(0 / 0) == Formulas.MIN_GAIT_BOB)

	-- The gait must not switch on while a player is standing still. A character resting
	-- against geometry still reports a fraction of a stud per second.
	check("a standstill has no gait", Formulas.MIN_GAIT_SPEED > 0)
	check("walking clears the gait threshold", Formulas.WalkSpeed(0) > Formulas.MIN_GAIT_SPEED)

	-- The three impact bands, and the combo weights that have to land in them. Punch's
	-- 0.3 / 0.45 / 0.8 is the whole of the escalation the player sees, so it is asserted
	-- here rather than left to the ability file: a retune of either the thresholds or the
	-- shares that flattened the combo would otherwise be silent.
	check("a jab reads light", Formulas.ImpactTier(0.3) == "Light")
	check("a cross reads solid", Formulas.ImpactTier(0.45) == "Solid")
	check("a finisher reads crushing", Formulas.ImpactTier(0.8) == "Crushing")
	check("a heavy reads crushing", Formulas.ImpactTier(1) == "Crushing")
	check("a grazing hit reads light", Formulas.ImpactTier(0) == "Light")
	check("the bands are ordered", Formulas.IMPACT_SOLID_WEIGHT < Formulas.IMPACT_CRUSHING_WEIGHT)
	check("impact tiers survive bad input", Formulas.ImpactTier(0 / 0) == "Light")

	check("total power sums", Formulas.TotalPower({ a = 2, b = 3 }) == 5)

	return failures
end

return Formulas
