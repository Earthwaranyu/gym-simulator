--!strict
--[[
	Token Pack — 800 tokens for 169 Robux.

	Tokens are the multiplier sink, so selling them sells progress.

	The number here is what the pack is worth to a Natural. AwardClassScaled converts it
	to the buyer's class, because token income doubles with every physique class and a
	flat grant would decay into a rounding error for exactly the players most likely to
	buy one. What the pack really sells is a fixed stretch of progress, at any point in
	the game — and because multiplier costs double too, it is never a route to the cap.

	AssetId must be set from the Roblox Creator Dashboard. Until it is,
	PurchaseService logs a warning at startup and refuses to prompt this product.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local TOKENS = 800

local Product: Types.Product = {
	Id = "TokenPack800",
	Kind = "DevProduct",
	AssetId = 0,
	DisplayName = "800 Tokens",
	Description = "Adds 800 tokens toward permanent muscle multipliers.",
	RobuxPrice = 169,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardClassScaled(player, TOKENS)
	end,
}

return Product
