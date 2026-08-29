--!strict
--[[
	Protein Shake — a ten-minute double-stats boost.

	Priced low on purpose. This is the impulse buy of the catalogue: it does nothing
	permanent, and ten minutes of doubled reps is enough to feel, not enough to skip a
	tier. Re-buying extends the timer rather than stacking the multiplier, so no amount
	of them is a shortcut past a tier — it only buys more of the same rate.

	The multiplier and duration used to live here, and before that in ShopConfig. They
	are in BoostConfig now so the HUD badge can read them; this file describes the
	product, not the boost. Originally they moved out of ShopConfig because the same item
	could also be bought with tokens.

	Live dev product on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)
local BoostConfig = require(ReplicatedStorage.Modules.BoostConfig)

local ITEM_ID = "ProteinShake"
local BOOST_ID = BoostConfig.IdFor(ITEM_ID)
-- The multiplier and duration live in BoostConfig, because the HUD badge has to read
-- them too and a client cannot require this module.
local BOOST = assert(BoostConfig.Get(BOOST_ID), `{BOOST_ID} is missing from BoostConfig`)

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 3709768828,
	DisplayName = "Protein Shake",
	Description = "2x all stats for 10 minutes.",
	RobuxPrice = 19,

	Grant = function(player: Player): boolean
		return Loader.Get("BoostService"):GrantGlobal(player, BOOST_ID, BOOST.Multiplier, BOOST.Duration)
	end,
}

return Product
