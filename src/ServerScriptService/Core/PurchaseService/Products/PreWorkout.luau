--!strict
--[[
	Pre-Workout — a three-minute triple-stats boost.

	Stronger and shorter than the Protein Shake, which is the whole point: it is the
	one you buy when you are already sitting on a machine, not the one you buy and
	forget. Three minutes is short enough that it cannot be spent idling.

	The multiplier and duration are read from ShopConfig rather than repeated here, so
	the shop UI describing the item and the code granting it can never drift apart.

	AssetId must be set from the Roblox Creator Dashboard. Until it is, PurchaseService
	logs a warning at startup and refuses to prompt this product.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local ITEM_ID = "PreWorkout"

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 0,
	DisplayName = "Pre-Workout",
	Description = "3x all stats for 3 minutes. Burns fast.",
	RobuxPrice = 35,

	Grant = function(player: Player): boolean
		local item = ShopConfig.Get(ITEM_ID)
		if item == nil then
			warn(`[{ITEM_ID}] No ShopConfig entry — the boost cannot be granted.`)
			return false
		end

		local effect = item.Effect
		Loader.Get("BoostService"):GrantGlobal(player, `Shop_{ITEM_ID}`, effect.Multiplier, effect.Duration)
		return true
	end,
}

return Product
