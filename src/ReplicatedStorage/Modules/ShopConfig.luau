--!strict
--[[
	ShopConfig — everything buyable with cash.

	Cash items are consumables and unlocks, never permanent power: permanent multipliers
	cost Tokens, which are earned by time rather than by grinding reps. Keeping those
	economies separate is what stops a long AFK session from buying its way to the top.

	Effect is declared as data, not as a function, so this table stays a pure
	description and ShopService owns all the granting. Adding an item is one entry;
	adding a new *kind* of effect is one branch in ShopService's applier.
]]

local Types = require(script.Parent.Types)

export type ShopEffect =
	-- Multiply every stat for a while.
	{ Kind: "GlobalBoost", Multiplier: number, Duration: number }
	-- Multiply one stat for a while.
	| { Kind: "StatBoost", StatId: Types.StatId, Multiplier: number, Duration: number }
	-- Permanently unlock a machine regardless of power requirement.
	| { Kind: "UnlockEquipment", EquipmentId: Types.EquipmentId }

export type ShopItem = {
	Id: string,
	DisplayName: string,
	Description: string,
	Price: number,
	-- True for one-shot permanent purchases, which are refused if already owned.
	OneTime: boolean,
	Effect: ShopEffect,
}

local items: { ShopItem } = {
	{
		Id = "ProteinShake",
		DisplayName = "Protein Shake",
		Description = "2x all stats for 10 minutes.",
		Price = 2500,
		OneTime = false,
		Effect = { Kind = "GlobalBoost", Multiplier = 2, Duration = 600 },
	},
	{
		Id = "PreWorkout",
		DisplayName = "Pre-Workout",
		Description = "3x all stats for 3 minutes. Burns fast.",
		Price = 4000,
		OneTime = false,
		Effect = { Kind = "GlobalBoost", Multiplier = 3, Duration = 180 },
	},
	{
		Id = "ArmDayFocus",
		DisplayName = "Arm Day Focus",
		Description = "4x Arms for 15 minutes.",
		Price = 3000,
		OneTime = false,
		Effect = { Kind = "StatBoost", StatId = "Arms", Multiplier = 4, Duration = 900 },
	},
	{
		Id = "UnlockPullUpBar",
		DisplayName = "Pull-Up Bar Pass",
		Description = "Use the Pull-Up Bar without meeting the power requirement.",
		Price = 10000,
		OneTime = true,
		Effect = { Kind = "UnlockEquipment", EquipmentId = "PullUpBar" },
	},
	{
		Id = "UnlockTreadmill",
		DisplayName = "Treadmill Pass",
		Description = "Use the Treadmill without meeting the power requirement.",
		Price = 25000,
		OneTime = true,
		Effect = { Kind = "UnlockEquipment", EquipmentId = "Treadmill" },
	},
}

local ShopConfig = {}

ShopConfig.List = items

local byId: { [string]: ShopItem } = {}
for _, item in items do
	if byId[item.Id] ~= nil then
		error(`[ShopConfig] Duplicate shop item id "{item.Id}"`)
	end
	byId[item.Id] = item
end

function ShopConfig.Get(itemId: string): ShopItem?
	return byId[itemId]
end

return ShopConfig
