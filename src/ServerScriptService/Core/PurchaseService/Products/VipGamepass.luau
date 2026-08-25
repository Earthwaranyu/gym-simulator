--!strict
--[[
	VIP — the flagship gamepass. Price comes from the Creator Dashboard.

	Grants a permanent 2x stat boost while owned, entitles the owner to claim one 1-hour
	immortal potion per day (VipService handles the claim), and unlocks the VIP title in
	RankConfig — the one thing about the pass that other players can see.

	Grant runs on every join as well as on purchase, so it must be idempotent. It is:
	the boost is registered by id in the modifier stack, and re-registering replaces
	rather than compounds.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Types = require(ReplicatedStorage.Modules.Types)

local VIP_MULTIPLIER = 2

local Product: Types.Product = {
	Id = "Vip",
	Kind = "Gamepass",
	AssetId = 1952620111,
	DisplayName = "VIP",
	Description = "2x all stats, plus a free 1-hour immortal potion every day.",
	RobuxPrice = 699,

	Grant = function(player: Player): boolean
		-- Permanent for the session: re-applied on every join by ApplyGamepasses.
		Loader.Get("BoostService"):GrantGlobal(player, "VipGamepass", VIP_MULTIPLIER, nil)
		-- So the title selector can paint the VIP row without a round trip. The server
		-- still checks ownership itself before equipping it — this attribute decides
		-- what the menu draws, never what a player may wear.
		player:SetAttribute("VipOwned", true)
		return true
	end,
}

return Product
