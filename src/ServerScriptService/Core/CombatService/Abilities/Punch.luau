--!strict
--[[
	Punch — the starter attack, and the reference implementation of Types.Ability.

	Everything an attack needs is declared here. CombatService discovers this file at
	startup; adding a Slam or a Dash means copying this shape into a new file in this
	folder, with no edits anywhere else.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)

-- Held as a constant rather than read back off the table: inside Execute, a reference
-- to `Punch` would resolve to a global, since the local is not yet bound while the
-- table constructor is still being evaluated.
local DAMAGE_MULTIPLIER = 1

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
		combatService:ApplyDamage(context.Attacker, target, baseDamage * DAMAGE_MULTIPLIER)
	end,
}

return Punch
