--!strict
--[[
	Protein Shake — a ten-minute double-stats boost.

	Priced low on purpose. This is the impulse buy of the catalogue: it does nothing
	permanent, it cannot be stacked into a shortcut, and ten minutes of doubled reps is
	enough to feel, not enough to skip a tier.

	The multiplier and duration used to live in ShopConfig, because the same item could
	also be bought with tokens. Boosts are Robux-only now, so this file is the only
	description of the item and the numbers live here.

	Live dev product on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local ITEM_ID = "ProteinShake"
local MULTIPLIER = 2
local DURATION = 600

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 3709768828,
	DisplayName = "Protein Shake",
	Description = "2x all stats for 10 minutes.",
	RobuxPrice = 19,

	Grant = function(player: Player): boolean
		Loader.Get("BoostService"):GrantGlobal(player, `Shop_{ITEM_ID}`, MULTIPLIER, DURATION)
		return true
	end,
}

return Product
