--!strict
--[[
	Protein Shake — a ten-minute double-stats boost.

	Priced low on purpose. This is the impulse buy of the catalogue: it does nothing
	permanent, it cannot be stacked into a shortcut, and ten minutes of doubled reps
	is worth roughly one token pack's early progress — enough to feel, not enough to
	skip a tier.

	The multiplier and duration are read from ShopConfig rather than repeated here, so
	the shop UI describing the item and the code granting it can never drift apart.

	AssetId must be set from the Roblox Creator Dashboard. Until it is, PurchaseService
	logs a warning at startup and refuses to prompt this product.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local ITEM_ID = "ProteinShake"

local Product: Types.Product = {
	Id = ITEM_ID,
	Kind = "DevProduct",
	AssetId = 0,
	DisplayName = "Protein Shake",
	Description = "2x all stats for 10 minutes.",
	RobuxPrice = 25,

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
