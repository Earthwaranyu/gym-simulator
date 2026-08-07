--!strict
--[[
	Fast Travel — 149 Robux gamepass.

	Travel between districts is free to anywhere you have the power for, but only
	from inside the spawn plaza. This lifts that: travel from wherever you are
	standing, without the walk or the flight back.

	It sells convenience, not progress. The power requirement on every district
	still applies to owners exactly as it does to everyone else, which is the line
	this game draws for immortality potions and VIP too — you can buy your way past
	an inconvenience, never past the grind.

	Grant does nothing, and that is not an oversight. There is no state to set:
	TravelService asks PurchaseService whether the player owns this pass at the
	moment they try to travel, so ownership is read live rather than mirrored onto
	the profile. That makes it trivially idempotent, and a refund takes effect
	immediately instead of surviving until the next migration.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)

local Product: Types.Product = {
	Id = "FastTravel",
	Kind = "Gamepass",
	AssetId = 0,
	DisplayName = "Fast Travel",
	Description = "Travel to any district you have unlocked from anywhere on the map, "
		.. "instead of only from the spawn plaza.",
	RobuxPrice = 149,

	Grant = function(_player: Player): boolean
		return true
	end,
}

return Product
