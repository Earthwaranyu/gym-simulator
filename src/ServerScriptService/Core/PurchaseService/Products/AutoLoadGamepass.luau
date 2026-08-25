--!strict
--[[
	Auto Load — permanent convenience gamepass.

	Owners may opt in or out. When enabled, each machine automatically loads the
	heaviest weight their relevant muscle can safely use. It never unlocks a zone,
	weight, or stat requirement and therefore saves setup taps rather than buying power.

	Live pass on the Creator Dashboard; PurchaseService registers it at startup.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)

local Product: Types.Product = {
	Id = "AutoLoad",
	Kind = "Gamepass",
	AssetId = 1955305572,
	DisplayName = "Auto Load",
	Description = "Automatically fits the heaviest load your trained muscle can handle. Toggle it any time.",
	RobuxPrice = 699,

	Grant = function(player: Player): boolean
		player:SetAttribute("AutoLoadOwned", true)
		return true
	end,
}

return Product
