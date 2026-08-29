--!strict
--[[
	ProductInfo — what Roblox says a product costs and looks like.

	Every Product module carries a RobuxPrice and, until now, that number was what the
	shop displayed. It was wrong for six of the seven live products — the shop quoted
	199 for a VIP pass Roblox charges 699 for — because the price lives on the Creator
	Dashboard and nothing made the code follow it. Copying today's numbers into the
	files would only move the drift to the next dashboard edit.

	So the dashboard is the source of truth for price and icon, and Types.Product's
	RobuxPrice becomes the fallback for when the call fails. The product icon comes
	free with the same call: the images were attached when the products were created,
	so the shop needs no uploaded art of its own.

	Two things this has to survive, because the shop must open either way:

	  * GetProductInfo yields and can throw — it is an HTTP call behind a method — so
	    every call is pcall'd and the cache is warmed off the request path.
	  * It is rate limited. Entries live for TTL seconds and a refresh serves the stale
	    entry while it runs, so a busy server makes one call per product per TTL rather
	    than one per shop opening.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Modules.Types)

local ProductInfo = {}

-- Long enough that a full server costs a handful of calls an hour, short enough that
-- a price changed on the dashboard reaches players the same session.
local TTL = 300

export type Info = {
	Price: number,
	Icon: string?,
}

type Entry = {
	Info: Info,
	FetchedAt: number,
	Refreshing: boolean,
}

local cache: { [number]: Entry } = {}
-- One warning per asset id, not one per lookup: a product Roblox cannot resolve would
-- otherwise fill the log every time anybody opens the shop.
local warned: { [number]: boolean } = {}

local function infoType(product: Types.Product): Enum.InfoType
	return if product.Kind == "Gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
end

-- Yields. Returns nil when Roblox could not answer, which the caller treats as
-- "keep whatever we had".
local function fetch(product: Types.Product): Info?
	local ok, result = pcall(function()
		return MarketplaceService:GetProductInfo(product.AssetId, infoType(product))
	end)
	if not ok or type(result) ~= "table" then
		if not warned[product.AssetId] then
			warned[product.AssetId] = true
			warn(`[ProductInfo] Could not read "{product.Id}" ({product.AssetId}): {result}`)
		end
		return nil
	end

	local price = result.PriceInRobux
	local icon = result.IconImageAssetId

	return {
		-- A product taken off sale reports no price. The config value is a better
		-- answer than zero, which would read as "free" on the card.
		Price = if type(price) == "number" then price else product.RobuxPrice,
		Icon = if type(icon) == "number" and icon > 0 then `rbxassetid://{icon}` else nil,
	}
end

local function refresh(product: Types.Product)
	local entry = cache[product.AssetId]
	if entry ~= nil then
		if entry.Refreshing then
			return
		end
		entry.Refreshing = true
	end

	task.spawn(function()
		local info = fetch(product)
		local current = cache[product.AssetId]
		if info ~= nil then
			cache[product.AssetId] = { Info = info, FetchedAt = os.clock(), Refreshing = false }
		elseif current ~= nil then
			-- Failed refresh: keep serving what we had, and let the TTL try again.
			current.Refreshing = false
			current.FetchedAt = os.clock()
		end
	end)
end

--[[
	Never yields. Returns the live price and icon when they are known, the product's own
	RobuxPrice and no icon when they are not, and starts a background refresh when the
	entry is stale or missing.
]]
function ProductInfo.Get(product: Types.Product): Info
	local fallback: Info = { Price = product.RobuxPrice, Icon = nil }
	if product.AssetId == 0 then
		return fallback
	end

	local entry = cache[product.AssetId]
	if entry == nil then
		refresh(product)
		return fallback
	end

	if os.clock() - entry.FetchedAt > TTL then
		refresh(product)
	end
	return entry.Info
end

--[[
	Fills the cache so the first shop opening of a server already shows live prices.
	Sequential on purpose: eleven products fetched at once is the shape of request burst
	that gets a server rate limited, and nothing is waiting on this.
]]
function ProductInfo.Warm(list: { Types.Product })
	task.spawn(function()
		for _, product in list do
			if product.AssetId ~= 0 then
				local info = fetch(product)
				if info ~= nil then
					cache[product.AssetId] = { Info = info, FetchedAt = os.clock(), Refreshing = false }
				end
				task.wait(0.1)
			end
		end
	end)
end

return ProductInfo
