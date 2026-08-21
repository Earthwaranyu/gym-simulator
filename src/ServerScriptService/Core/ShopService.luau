--!strict
--[[
	ShopService — spends Tokens on the ShopConfig catalogue.

	Server-authoritative in the usual way: the client sends an item id and nothing else.
	The price is recomputed here from the buyer's own physique class, so a client that
	lies about its class, or simply holds a stale one from before a transformation, buys
	at the price the server works out rather than the one its screen was showing.

	This existed once and bought things with cash. Cash was removed and it went with it;
	Tokens are the soft currency now, and the shape of the thing is unchanged because it
	was right the first time — charge, apply, refund if the apply fails.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local ShopService = {
	Name = "ShopService",
	Priority = 19,
}

local DataService: any = nil
local TokenService: any = nil
local BoostService: any = nil
local FlagService: any = nil

function ShopService:Init()
	DataService = Loader.Get("DataService")
	TokenService = Loader.Get("TokenService")
	BoostService = Loader.Get("BoostService")
	FlagService = Loader.Get("FlagService")
end

--[[
	What this player pays right now.

	The class multiplier is the same number TokenService multiplies their income by, so
	the price and the earning move together and an item costs the same stretch of
	playing whoever buys it.
]]
function ShopService:PriceFor(player: Player, item: ShopConfig.ShopItem): number
	local data = DataService:GetData(player)
	local level = if data ~= nil then data.MuscleClassLevel else 0
	local class = MuscleClassConfig.Get(level)
	return ShopConfig.PriceFor(item, class.TokenMultiplier, Formulas.TokensPerMinute())
end

--[[
	Applies an item's effect. The one place shop effects are interpreted — a new effect
	kind adds a branch here and nowhere else.
]]
function ShopService:_apply(player: Player, item: ShopConfig.ShopItem): boolean
	local effect = item.Effect

	if effect.Kind == "GlobalBoost" then
		BoostService:GrantGlobal(player, `Shop_{item.Id}`, effect.Multiplier, effect.Duration)
		return true
	end

	warn(`[ShopService] Item "{item.Id}" has an unhandled effect kind`)
	return false
end

--[[
	Buys an item. Returns (success, message) — the message is shown verbatim in a toast.
]]
function ShopService:Purchase(player: Player, itemId: string): (boolean, string)
	-- The same kill switch the Robux path checks, so closing the store closes all of it
	-- rather than half.
	if FlagService:Get(player, "ShopEnabled") == false then
		return false, "The store is temporarily closed."
	end

	local item = ShopConfig.Get(itemId)
	if item == nil then
		return false, "That item does not exist."
	end

	if DataService:GetData(player) == nil then
		return false, "Your data is still loading."
	end

	local price = self:PriceFor(player, item)

	-- Charge first, then apply, then refund on failure. Checking the balance and
	-- spending as two steps would leave a window where the effect lands and the charge
	-- does not.
	if not TokenService:TrySpendTokens(player, price) then
		return false, `You need {NumberFormat.Format(price)} tokens for that.`
	end

	if not self:_apply(player, item) then
		TokenService:AwardTokens(player, price)
		return false, "Something went wrong applying that item."
	end

	return true, `Bought {item.DisplayName}.`
end

function ShopService:Start()
	Net.BindFunction("PurchaseShopItem", 4, function(player: Player, itemId: any)
		if type(itemId) ~= "string" then
			return false, "Invalid request."
		end
		return self:Purchase(player, itemId)
	end)

	-- The client needs the prices to draw the shop, and they depend on a class it would
	-- otherwise have to compute for itself. Handing them over keeps one source of truth
	-- for what a Protein Shake costs.
	Net.BindFunction("GetShopPrices", 2, function(player: Player)
		local prices: { [string]: number } = {}
		for _, item in ShopConfig.List do
			prices[item.Id] = self:PriceFor(player, item)
		end
		return prices
	end)
end

return ShopService
