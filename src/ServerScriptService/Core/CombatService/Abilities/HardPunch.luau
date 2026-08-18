--!strict
--[[
	Hard Punch — one heavy hit, and the move Block exists to answer.

	Punch splits its damage across three fast contacts and is what you throw when you
	are not thinking. This throws all of it at once, three times as hard, and takes
	nearly half a second of visible wind-up to do it.

	That wind-up is the whole design. A heavy hit that could not be seen coming would
	just be a better punch with a cooldown, and Block would have nothing to react to —
	you cannot guard a jab you learn about when the damage number appears. HEAVY_LOAD
	in StrikeConfig exists for the same reason: the arm visibly stops at full tension
	before release, so the opponent gets a frame that says "now".

	Which also means the counter-play is real. Committing to this against somebody
	holding F is worse than throwing two jabs, and that is the trade the move is for.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)

local STRIKE = StrikeConfig.Get("HardPunch")
assert(STRIKE ~= nil, "StrikeConfig must define HardPunch")
local ENTRY = AbilityConfig.Get("HardPunch")
assert(ENTRY ~= nil, "AbilityConfig must define HardPunch")

local RANGE = 18
-- The same latency generosity Punch applies to its own contact re-check. A heavy is
-- in the air noticeably longer than a jab, so a target who backpedals during the wind
-- has genuinely escaped it — but one who is still standing where they were should not
-- be missed over a stud of network drift.
local CONTACT_RANGE = RANGE * 1.35

local Heavy: Types.Ability = {
	Id = "HardPunch",
	DisplayName = ENTRY.DisplayName,
	Cooldown = ENTRY.Cooldown,
	Range = RANGE,
	DamageMultiplier = Formulas.HARD_PUNCH_MULTIPLIER,
	AutoTarget = true,
	-- False, exactly as Punch is, and for exactly the same reason: a heavy swung at
	-- empty air is still a heavy swung, and a player alone in a gym who presses R
	-- should see the animation. CombatService has already discarded a dead or
	-- out-of-range target before Execute runs, so a nil target here is a real miss.
	RequiresTarget = false,

	Execute = function(context: Types.AbilityContext, combatService: any)
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE, "HardPunch")
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ATTRIBUTE, workspace:GetServerTimeNow())

		local target = context.CombatTarget
		if target == nil then
			return
		end

		local attacker = context.Attacker
		local baseDamage = combatService:GetBaseDamage(attacker)
		local arms = combatService:GetStat(attacker, "Arms")
		local attackerRoot = context.AttackerRoot
		local targetRoot = target.Root

		task.delay(STRIKE.Duration * STRIKE.Contacts[1], function()
			if
				attackerRoot.Parent == nil
				or targetRoot.Parent == nil
				or (attackerRoot.Position - targetRoot.Position).Magnitude > CONTACT_RANGE
			then
				return
			end

			-- Full weight: one blow, and meant to be the hardest single thing a player
			-- can throw without a cooldown measured in seconds.
			combatService:ApplyDamageToTarget(
				attacker,
				target,
				baseDamage * Formulas.HARD_PUNCH_MULTIPLIER,
				1
			)

			-- Straight back, away from the puncher. Knockback lands whether or not the
			-- damage did, on the same reasoning as the slam: a guard stops the harm,
			-- not the force, and a blocked heavy that moved nobody would look like it
			-- had been ignored rather than absorbed.
			local back = if target.Player ~= nil then combatService:GetStat(target.Player, "Back") else 0
			combatService:ApplyKnockback(
				target,
				targetRoot.Position - attackerRoot.Position,
				Formulas.KnockbackSpeed(arms, back)
			)
		end)
	end,
}

return Heavy
