--!strict
--[[
	Immortal Potion — 1 hour, 19 Robux.

	Reference implementation of Types.Product. Copy this shape into a new file in this
	folder to add a product; nothing else changes.

	Live dev product on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local ONE_HOUR = 60 * 60

local Product: Types.Product = {
	Id = "ImmortalPotion1Hour",
	Kind = "DevProduct",
	AssetId = 3709768660,
	DisplayName = "Immortal Potion (1 Hour)",
	Description = "No one can touch you for one hour. Train in peace.",
	RobuxPrice = 19,

	Grant = function(player: Player): boolean
		return Loader.Get("ImmortalityService"):Grant(player, ONE_HOUR)
	end,
}

return Product
