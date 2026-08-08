--!strict
--[[
	StatConfig — the single declaration of the game's core stats.

	This is the only file that knows the stats exist. StatService, the HUD, the muscle
	deformer, and the combat model all read from here, so adding a sixth stat means
	adding one entry below and nothing else: no migration (ProfileTemplate starts Stats
	empty), no UI edit (the HUD iterates List), no type change (StatId is a string).

	BodyScales maps a stat to the R15 parts it inflates, with a weight for how strongly.
	MuscleService turns those into the NumberValues that drive MeshPart scaling.
]]

local Types = require(script.Parent.Types)
local Formulas = require(script.Parent.Formulas)

export type StatDefinition = {
	Id: Types.StatId,
	DisplayName: string,
	-- Drives the stat's HUD row and its muscle-growth tint.
	Color: Color3,
	-- Short blurb for the training station tooltip.
	Description: string,
	-- What this stat is currently worth to this player, as a short line: "38 damage
	-- a hit", "412 max health". Nothing in the game used to say what a stat was
	-- FOR — the HUD showed five numbers and no meaning, and Back could be trained
	-- for an hour before you noticed it changed nothing.
	--
	-- A function on the definition rather than a switch somewhere downstream, so a
	-- sixth stat arrives carrying its own explanation and no consumer ever branches
	-- on a stat id.
	Effect: (stats: { [string]: number }) -> string,
	-- R15 part name -> how much this stat inflates it, relative to other stats.
	BodyScales: { [string]: number },
}

local function get(stats: { [string]: number }, id: string): number
	return stats[id] or 0
end

-- Display order is this array's order.
local definitions: { StatDefinition } = {
	{
		Id = "Arms",
		DisplayName = "Arms",
		Color = Color3.fromRGB(239, 83, 80),
		Description = "Raw punching power. Every point of damage you deal starts here.",
		Effect = function(stats)
			return `{string.format("%.0f", Formulas.AttackDamage(get(stats, "Arms")))} damage a hit`
		end,
		BodyScales = {
			LeftUpperArm = 1.0,
			RightUpperArm = 1.0,
			LeftLowerArm = 0.8,
			RightLowerArm = 0.8,
		},
	},
	{
		Id = "Chest",
		DisplayName = "Chest",
		Color = Color3.fromRGB(255, 167, 38),
		Description = "How much punishment you can take before you drop.",
		Effect = function(stats)
			return `{string.format("%.0f", Formulas.MaxHealth(get(stats, "Chest")))} max health`
		end,
		BodyScales = {
			UpperTorso = 1.0,
		},
	},
	{
		Id = "Back",
		DisplayName = "Back",
		Color = Color3.fromRGB(102, 187, 106),
		Description = "Braced against heavier hitters. Blunts damage from anyone whose Arms trail your Back.",
		Effect = function(stats)
			-- Resistance is contested, so there is no single number for it. Quoted
			-- against an attacker with nothing in Arms, which is the ceiling, and
			-- labelled as such rather than pretending it applies to everyone.
			local best = Formulas.DamageResistance(get(stats, "Back"), 0)
			if best < 0.005 then
				return "no damage reduction yet"
			end
			return `up to -{string.format("%.0f", best * 100)}% damage taken`
		end,
		BodyScales = {
			UpperTorso = 0.6,
		},
	},
	{
		Id = "Core",
		DisplayName = "Core",
		Description = "Hitting you costs the attacker. A share of every blow goes straight back.",
		Effect = function(stats)
			return `{string.format("%.0f", Formulas.Retaliation(get(stats, "Core"), 100))}% of hits sent back`
		end,
		Color = Color3.fromRGB(66, 165, 245),
		BodyScales = {
			LowerTorso = 1.0,
		},
	},
	{
		Id = "Legs",
		DisplayName = "Legs",
		Color = Color3.fromRGB(171, 71, 188),
		Description = "Ground speed and air speed. The stat that makes the map smaller.",
		Effect = function(stats)
			local legs = get(stats, "Legs")
			return `{string.format("%.0f", Formulas.SprintSpeed(legs))} sprint · `
				.. `{string.format("%.0f", Formulas.FlightSpeed(legs))} fly`
		end,
		BodyScales = {
			LeftUpperLeg = 1.0,
			RightUpperLeg = 1.0,
			LeftLowerLeg = 0.8,
			RightLowerLeg = 0.8,
		},
	},
}

local StatConfig = {}

StatConfig.List = definitions

local byId: { [Types.StatId]: StatDefinition } = {}
for _, definition in definitions do
	if byId[definition.Id] ~= nil then
		error(`[StatConfig] Duplicate stat id "{definition.Id}"`)
	end
	byId[definition.Id] = definition
end

--[[
	The definition for a stat id, or nil if it is not a real stat. Server code should
	treat nil as a rejected client request rather than an error.
]]
function StatConfig.Get(statId: Types.StatId): StatDefinition?
	return byId[statId]
end

function StatConfig.IsValid(statId: Types.StatId): boolean
	return byId[statId] ~= nil
end

function StatConfig.Count(): number
	return #StatConfig.List
end

return StatConfig
