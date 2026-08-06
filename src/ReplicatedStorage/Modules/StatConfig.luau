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

export type StatDefinition = {
	Id: Types.StatId,
	DisplayName: string,
	-- Drives the stat's HUD row and its muscle-growth tint.
	Color: Color3,
	-- Short blurb for the training station tooltip.
	Description: string,
	-- R15 part name -> how much this stat inflates it, relative to other stats.
	BodyScales: { [string]: number },
}

-- Display order is this array's order.
local definitions: { StatDefinition } = {
	{
		Id = "Arms",
		DisplayName = "Arms",
		Color = Color3.fromRGB(239, 83, 80),
		Description = "Raw punching power. Drives most of your PvP damage.",
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
		Description = "Pressing strength. Adds to damage and to how wide you get.",
		BodyScales = {
			UpperTorso = 1.0,
		},
	},
	{
		Id = "Back",
		DisplayName = "Back",
		Color = Color3.fromRGB(102, 187, 106),
		Description = "Pulling strength. Broadens the frame.",
		BodyScales = {
			UpperTorso = 0.6,
		},
	},
	{
		Id = "Core",
		DisplayName = "Core",
		Description = "Toughness. Sets your max health and stamina pool.",
		Color = Color3.fromRGB(66, 165, 245),
		BodyScales = {
			LowerTorso = 1.0,
		},
	},
	{
		Id = "Legs",
		DisplayName = "Legs",
		Color = Color3.fromRGB(171, 71, 188),
		Description = "Movement speed. Catch people, or escape them.",
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
