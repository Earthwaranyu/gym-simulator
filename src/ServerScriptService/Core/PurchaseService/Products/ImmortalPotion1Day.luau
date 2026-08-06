--!strict
--[[
	Immortal Potion — 1 day, 79 Robux.

	Time stacks onto any potion still running, so buying this while an hour potion is
	active never wastes the remainder.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local ONE_DAY = 24 * 60 * 60

local Product: Types.Product = {
	Id = "ImmortalPotion1Day",
	Kind = "DevProduct",
	AssetId = 0,
	DisplayName = "Immortal Potion (1 Day)",
	Description = "A full day of immunity. Expiry is saved, so it survives rejoining.",
	RobuxPrice = 79,

	Grant = function(player: Player): boolean
		return Loader.Get("ImmortalityService"):Grant(player, ONE_DAY)
	end,
}

return Product
