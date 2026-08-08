--!strict
--[[
	Token Pack — 1600 tokens for 299 Robux.

	Tokens are the multiplier sink. Selling them sells progress, which is why the
	packs are priced against the cost curve rather than against a round number:
	Formulas.MultiplierCost grows 1.35x per level, so a pack buys a visible jump
	early and a much smaller one later. Nobody buys their way to the cap.

	AssetId must be set from the Roblox Creator Dashboard. Until it is,
	PurchaseService logs a warning at startup and refuses to prompt this product.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local TOKENS = 1600

local Product: Types.Product = {
	Id = "TokenPack1600",
	Kind = "DevProduct",
	AssetId = 0,
	DisplayName = "1600 Tokens",
	Description = "Adds 1600 tokens to spend on permanent per-stat multipliers.",
	RobuxPrice = 299,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardTokens(player, TOKENS)
	end,
}

return Product
