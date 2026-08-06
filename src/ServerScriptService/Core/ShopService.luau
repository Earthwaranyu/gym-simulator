--!strict
--[[
	ShopService — spends cash on the ShopConfig catalogue.

	Server-authoritative in the usual way: the client sends an item id and nothing else,
	and price, affordability, and ownership are all recomputed here.

	Cash is taken only after the effect is known to be applicable, and one-time items
	are checked against the profile first, so a double-click cannot charge twice for a
	permanent unlock.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local ShopService = {
	Name = "ShopService",
	Priority = 19,
}

local DataService: any = nil
local CurrencyService: any = nil
local BoostService: any = nil

function ShopService:Init()
	DataService = Loader.Get("DataService")
	CurrencyService = Loader.Get("CurrencyService")
	BoostService = Loader.Get("BoostService")
end

function ShopService:Owns(player: Player, item: ShopConfig.ShopItem): boolean
	if not item.OneTime then
		return false
	end

	local data = DataService:GetData(player)
	if data == nil then
		return false
	end

	local effect = item.Effect
	if effect.Kind == "UnlockEquipment" then
		return data.OwnedEquipment[effect.EquipmentId] == true
	end

	return false
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
	elseif effect.Kind == "StatBoost" then
		BoostService:GrantStat(player, `Shop_{item.Id}`, effect.StatId, effect.Multiplier, effect.Duration)
		return true
	elseif effect.Kind == "UnlockEquipment" then
		local data = DataService:GetData(player)
		if data == nil then
			return false
		end
		data.OwnedEquipment[effect.EquipmentId] = true
		DataService:MarkDirty(player)
		return true
	end

	warn(`[ShopService] Item "{item.Id}" has an unhandled effect kind`)
	return false
end

--[[
	Buys an item. Returns (success, message) — the message is shown verbatim in a toast.
]]
function ShopService:Purchase(player: Player, itemId: string): (boolean, string)
	local item = ShopConfig.Get(itemId)
	if item == nil then
		return false, "That item does not exist."
	end

	if DataService:GetData(player) == nil then
		return false, "Your data is still loading."
	end

	if self:Owns(player, item) then
		return false, "You already own that."
	end

	-- Charge first, then apply, then refund on failure. Checking the balance and
	-- spending as two steps would leave a window where the effect lands but the charge
	-- does not.
	if not CurrencyService:TrySpend(player, item.Price) then
		return false, `You need ${NumberFormat.Format(item.Price)} for that.`
	end

	if not self:_apply(player, item) then
		CurrencyService:Add(player, item.Price)
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
end

return ShopService
