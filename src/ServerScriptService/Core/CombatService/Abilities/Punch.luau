--!strict
--[[
	Punch — the starter attack, and the reference implementation of Types.Ability.

	Everything an attack needs is declared here. CombatService discovers this file at
	startup; adding a Slam or a Dash means copying this shape into a new file in this
	folder, with no edits anywhere else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

-- Held as a constant rather than read back off the table: inside Execute, a reference
-- to `Punch` would resolve to a global, since the local is not yet bound while the
-- table constructor is still being evaluated.
local DAMAGE_MULTIPLIER = 1

-- Throwing a punch is arm training, so a landed hit pays Arms.
--
-- Deliberately worth less than standing at a machine. A machine pays one base stat
-- per second; at the 0.6s cooldown this is 0.25 per hit, about 0.42/s, and only when
-- a hit actually connects on a living victim. Fighting therefore adds to a session
-- without ever being the efficient way to train — which matters because the victim
-- is losing training time while it happens.
local ARMS_PER_HIT = 0.25

local Punch: Types.Ability = {
	Id = "Punch",
	DisplayName = "Punch",
	Cooldown = 0.6,
	Range = 12,
	DamageMultiplier = DAMAGE_MULTIPLIER,
	RequiresTarget = true,

	Execute = function(context: Types.AbilityContext, combatService: any)
		local target = context.Target
		if target == nil then
			return
		end

		local baseDamage = combatService:GetBaseDamage(context.Attacker)
		local dealt = combatService:ApplyDamage(context.Attacker, target, baseDamage * DAMAGE_MULTIPLIER)

		-- Only a hit that actually landed pays. ApplyDamage returns zero for a dead or
		-- immortal victim, and swinging at a barrier should not train anything.
		if dealt > 0 then
			-- Through AddStat, so the gain passes the modifier stack and composes with
			-- token multipliers and boosts exactly like a rep does.
			Loader.Get("StatService"):AddStat(context.Attacker, "Arms", ARMS_PER_HIT)
		end
	end,
}

return Punch
