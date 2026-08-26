--!strict
--[[
	Token Pack (Huge) — 5,000 tokens, about twenty hours of training.

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

local TOKENS = 5000

local Product: Types.Product = {
	Id = "TokenPackHuge",
	Kind = "DevProduct",
	AssetId = 3709886164,
	DisplayName = "Huge Token Pack",
	Description = "About twenty hours of training.",
	TokenGrant = TOKENS,
	RobuxPrice = 399,

	Grant = function(player: Player): boolean
		return Loader.Get("TokenService"):AwardClassScaled(player, TOKENS)
	end,
}

return Product
