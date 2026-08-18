--!strict
--[[
	Punch — the starter attack, and the reference implementation of Types.Ability.

	Everything an attack needs is declared here. CombatService discovers this file at
	startup; adding a Slam or a Dash means copying this shape into a new file in this
	folder, with no edits anywhere else.

	An attack deals damage and nothing else. No stat gain, no power: power comes from
	the machines, and combat is what takes it away from somebody.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)

-- Held as a constant rather than read back off the table: inside Execute, a reference
-- to `Punch` would resolve to a global, since the local is not yet bound while the
-- table constructor is still being evaluated.
local DAMAGE_MULTIPLIER = 1
local STRIKE = StrikeConfig.Get("Punch")
assert(STRIKE ~= nil, "StrikeConfig must define Punch")
-- The three contacts add back to the old one-punch total. Later hits are heavier so
-- the finisher feels important without making one input deal triple damage.
local CONTACT_DAMAGE_SHARES = { 0.25, 0.3, 0.45 }
-- How hard each contact reads, which is a separate question from how much it hurts. The
-- damage shares above are nearly flat by comparison, because the three of them have to
-- total one punch; these are what make the third hit feel like the point of the combo.
-- The jab taps, the cross bites, the finisher lands in the crushing band — Formulas'
-- self-test asserts exactly that mapping, so retuning either list cannot quietly flatten
-- the escalation.
local CONTACT_IMPACTS = { 0.3, 0.45, 0.8 }
local CONTACT_RANGE = 18 * 1.35

local Punch: Types.Ability = {
	Id = "Punch",
	DisplayName = "Punch",
	Cooldown = STRIKE.Duration,
	Range = 18,
	DamageMultiplier = DAMAGE_MULTIPLIER,
	AutoTarget = true,
	-- False so a swing at empty air still reaches Execute. The punch animation is
	-- thrown by the server (below) and a punch that only animated when it connected
	-- meant a player standing alone in a gym pressed the attack and saw nothing at
	-- all. CombatService still discards a target that is dead or out of range before
	-- calling in, so "no target" here means exactly that and the damage below is
	-- unreachable without a valid victim.
	RequiresTarget = false,

	Execute = function(context: Types.AbilityContext, combatService: any)
		-- The swing happens first and unconditionally, because throwing a punch and
		-- landing one are different events. Every client watches this attribute and
		-- plays the animation locally (StrikeController); nothing about the animation
		-- itself is replicated, because the numbers already ship with the game.
		--
		-- A number rather than a flag so two punches in a row are two events, and
		-- stamped on the character rather than sent to the attacker so that everyone
		-- in the room sees the arm go out — including the victim, for whom it is the
		-- only warning they are being attacked.
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE, "Punch")
		context.AttackerCharacter:SetAttribute(StrikeConfig.STRIKE_ATTRIBUTE, workspace:GetServerTimeNow())

		-- Everything past here is the hit, which needs something to hit. CombatTarget
		-- rather than Target: a punch lands on a goblin exactly as it lands on a
		-- player, and ApplyDamageToTarget is what knows the difference.
		local target = context.CombatTarget
		if target == nil then
			return
		end

		local baseDamage = combatService:GetBaseDamage(context.Attacker)
		local attackerRoot = context.AttackerRoot
		local targetRoot = target.Root
		for index, contact in STRIKE.Contacts do
			local share = CONTACT_DAMAGE_SHARES[index]
			task.delay(STRIKE.Duration * contact, function()
				if
					attackerRoot.Parent == nil
					or targetRoot.Parent == nil
					or (attackerRoot.Position - targetRoot.Position).Magnitude > CONTACT_RANGE
				then
					return
				end
				combatService:ApplyDamageToTarget(
					context.Attacker,
					target,
					baseDamage * DAMAGE_MULTIPLIER * share,
					CONTACT_IMPACTS[index]
				)
			end)
		end

		-- Deliberately no knockback, where the heavy and the slam both have one.
		-- CONTACT_RANGE is 24 studs and the slowest knockback is 40 studs a second, so
		-- shoving the target on the first contact would carry them out of reach of the
		-- second and third and quietly turn a three-hit combo into a one-hit move. The
		-- flinch is what says the hit landed; the shove belongs to the attacks that are
		-- over in one blow.

		-- Landing a hit pays no stats. It used to pay 0.25 Arms, on the reasoning that
		-- throwing a punch is arm training — but that made hitting people a way to
		-- grow the stat that makes you hit harder, and the whole point of the machines
		-- is that training is where power comes from. Fighting costs the victim their
		-- training time; it is not a second way to earn.
	end,
}

return Punch
