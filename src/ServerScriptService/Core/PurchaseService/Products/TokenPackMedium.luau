--!strict
--[[
	Token Pack (Medium) — 750 tokens, about three hours of training.

	See TokenPackSmall for the arithmetic: TOKENS is Natural-quoted and AwardClassScaled
	converts it to the buyer's class, so what this really sells is a fixed stretch of
	progress at any point in the game.

	The AssetId is the live developer product on the Roblox Creator Dashboard, with
	managed pricing off so the Robux price below is the one the buyer sees. RobuxPrice
	is only the fallback ProductInfo quotes before its first fetch lands.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local TOKENS = 750

local Product: Types.Product = {
	Id = "TokenPackMedium",
	Kind = "DevProduct",
	AssetId = 3709886078,
	DisplayName = "Medium Token Pack",
	Description = "About three hours of training.",
	TokenGrant = TOKENS,
	RobuxPrice = 99,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardClassScaled(player, TOKENS)
	end,
}

return Product
