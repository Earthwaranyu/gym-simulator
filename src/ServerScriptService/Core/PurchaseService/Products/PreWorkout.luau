--!strict
--[[
	Pre-Workout — a three-minute triple-stats boost.

	Stronger and shorter than the Protein Shake, which is the whole point: it is the
	one you buy when you are already sitting on a machine, not the one you buy and
	forget. Three minutes is short enough that it cannot be spent idling.

	The multiplier and duration used to live here, and before that in ShopConfig. They
	are in BoostConfig now so the HUD badge can read them; this file describes the
	product, not the boost. Originally they moved out of ShopConfig because the same item
	could also be bought with tokens and the two prices had to agree about what a
	Pre-Workout was.

	Live dev product on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)
local BoostConfig = require(ReplicatedStorage.Modules.BoostConfig)

local ITEM_ID = "PreWorkout"
local BOOST_ID = BoostConfig.IdFor(ITEM_ID)
-- The multiplier and duration live in BoostConfig, because the HUD badge has to read
-- them too and a client cannot require this module.
local BOOST = assert(BoostConfig.Get(BOOST_ID), `{BOOST_ID} is missing from BoostConfig`)

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 3709768865,
	DisplayName = "Pre-Workout",
	Description = "3x all stats for 3 minutes. Burns fast.",
	RobuxPrice = 29,

	Grant = function(player: Player): boolean
		return Loader.Get("BoostService"):GrantGlobal(player, BOOST_ID, BOOST.Multiplier, BOOST.Duration)
	end,
}

return Product
