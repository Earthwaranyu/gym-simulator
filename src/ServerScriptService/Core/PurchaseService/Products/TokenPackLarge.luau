--!strict
--[[
	Token Pack (Large) — 2,000 tokens, about eight hours of training.

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

local TOKENS = 2000

local Product: Types.Product = {
	Id = "TokenPackLarge",
	Kind = "DevProduct",
	AssetId = 3709886119,
	DisplayName = "Large Token Pack",
	Description = "About eight hours of training.",
	TokenGrant = TOKENS,
	RobuxPrice = 199,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardClassScaled(player, TOKENS)
	end,
}

return Product
