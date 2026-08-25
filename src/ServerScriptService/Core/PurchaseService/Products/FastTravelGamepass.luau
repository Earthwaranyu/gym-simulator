--!strict
--[[
	Fast Travel — 149 Robux gamepass.

	The map lets everyone track any training location. This pass unlocks the separate
	Teleport action for every destination where the relevant muscle is strong enough.

	It sells convenience, not progress. The muscle requirement on every district
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
	AssetId = 1954945633,
	DisplayName = "Fast Travel",
	Description = "Teleport to any map destination your relevant muscle has unlocked.",
	RobuxPrice = 149,

	Grant = function(_player: Player): boolean
		return true
	end,
}

return Product
