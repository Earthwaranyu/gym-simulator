--!strict
--[[
	Pre-Workout — a three-minute triple-stats boost.

	Stronger and shorter than the Protein Shake, which is the whole point: it is the
	one you buy when you are already sitting on a machine, not the one you buy and
	forget. Three minutes is short enough that it cannot be spent idling.

	The multiplier and duration used to live in ShopConfig, because the same item could
	also be bought with tokens and the two prices had to agree about what a Pre-Workout
	was. Boosts are Robux-only now, so this file is the only description of the item and
	the numbers live here.

	Live dev product on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local ITEM_ID = "PreWorkout"
local MULTIPLIER = 3
local DURATION = 180

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 3709768865,
	DisplayName = "Pre-Workout",
	Description = "3x all stats for 3 minutes. Burns fast.",
	RobuxPrice = 29,

	Grant = function(player: Player): boolean
		Loader.Get("BoostService"):GrantGlobal(player, `Shop_{ITEM_ID}`, MULTIPLIER, DURATION)
		return true
	end,
}

return Product
