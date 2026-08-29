--!strict
--[[
	PurchaseService — Robux dev products and gamepasses.

	Named PurchaseService rather than MarketplaceService so it cannot be confused with
	Roblox's own service of that name, which it wraps.

	Products live in Products/ and are discovered at startup, the same pattern as combat
	abilities. Adding a potion or a gamepass is one new file implementing Types.Product;
	there is no branch in the receipt handler to extend.

	Receipts are idempotent. Roblox retries ProcessReceipt until it is acknowledged, so
	a network blip between granting and returning PurchaseGranted would otherwise hand
	out the same product twice. Every granted PurchaseId is recorded on the profile
	before the grant is acknowledged.

	Receipts are also refused, not swallowed, when a player's data has not loaded —
	returning NotProcessedYet makes Roblox retry later instead of taking the money for
	something that was never granted.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)

local ProductInfo = require(script.ProductInfo)

local PurchaseService = {
	Name = "PurchaseService",
	Priority = 21,
}

--- (player, productId) — a Robux prompt was opened.
PurchaseService.ProductPrompted = Signal.new()
--- (player, productId, result) — "Granted", "Declined", or "Failed".
PurchaseService.PurchaseResolved = Signal.new()

local products: { [string]: Types.Product } = {}
local devProductsByAssetId: { [number]: Types.Product } = {}
local gamepasses: { Types.Product } = {}

local DataService: any = nil

function PurchaseService:Init()
	DataService = Loader.Get("DataService")
	self:_loadProducts()
end

function PurchaseService:_loadProducts()
	local folder = script:FindFirstChild("Products")
	if folder == nil then
		warn("[PurchaseService] No Products folder — nothing is purchasable.")
		return
	end

	for _, module in folder:GetChildren() do
		if not module:IsA("ModuleScript") then
			continue
		end

		local ok, result = pcall(require, module)
		if not ok then
			warn(`[PurchaseService] Failed to load product {module.Name}: {result}`)
			continue
		end

		local product = result :: Types.Product
		if type(product) ~= "table" or type(product.Id) ~= "string" or type(product.Grant) ~= "function" then
			warn(`[PurchaseService] {module.Name} does not implement the Product contract`)
			continue
		end

		products[product.Id] = product

		if product.AssetId == 0 then
			-- Deliberately not registered: an unset id would collide with any other
			-- unset id, and could match a malformed receipt.
			warn(
				`[PurchaseService] "{product.Id}" has AssetId 0 — create it in the Creator `
					.. `Dashboard and set the id before shipping. It cannot be purchased until then.`
			)
			continue
		end

		if product.Kind == "Gamepass" then
			table.insert(gamepasses, product)
		else
			devProductsByAssetId[product.AssetId] = product
		end
	end
end

function PurchaseService:GetProduct(productId: string): Types.Product?
	return products[productId]
end

function PurchaseService:GetProducts(): { [string]: Types.Product }
	return products
end

--[[
	Whether the player owns a gamepass. Wrapped in pcall because the Roblox call is a
	network request that genuinely fails, and a failure must read as "not owned"
	rather than erroring the caller.

	Cached for OWNERSHIP_TTL seconds, because the shop screen re-renders on every
	profile push — a token tick, a rep — and each render asked this question once per
	gamepass. A player who left the shop open while training was firing three uncached
	web requests a tick at the rate limiter.

	The TTL stays short and a purchase clears the entry outright, so the two ways
	ownership changes are both covered: buying in-game is immediate, and buying on the
	website or in another server shows up within the minute.
]]
local OWNERSHIP_TTL = 60

type OwnershipEntry = { Owns: boolean, ReadAt: number }
local ownership: { [Player]: { [number]: OwnershipEntry } } = {}

local function forgetOwnership(player: Player, assetId: number?)
	local byAsset = ownership[player]
	if byAsset == nil then
		return
	end
	if assetId == nil then
		ownership[player] = nil
	else
		byAsset[assetId] = nil
	end
end

function PurchaseService:OwnsGamepass(player: Player, assetId: number): boolean
	if assetId == 0 then
		return false
	end

	local byAsset = ownership[player]
	if byAsset == nil then
		byAsset = {}
		ownership[player] = byAsset
	end

	local entry = byAsset[assetId]
	if entry ~= nil and os.clock() - entry.ReadAt < OWNERSHIP_TTL then
		return entry.Owns
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, assetId)
	end)

	local answer = ok and owns == true
	-- A failed call is not cached as "not owned": that would hold a VIP out of their
	-- own pass for a minute because one request timed out.
	if ok then
		byAsset[assetId] = { Owns = answer, ReadAt = os.clock() }
	end
	return answer
end

--[[
	Re-applies every owned gamepass. Gamepass grants must be idempotent because this
	runs on every join.
]]
function PurchaseService:ApplyGamepasses(player: Player)
	for _, product in gamepasses do
		if self:OwnsGamepass(player, product.AssetId) then
			product.Grant(player)
		end
	end
end

function PurchaseService:_processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		-- They left mid-purchase. Retry when they return rather than consuming it.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local data = DataService:GetData(player)
	if data == nil then
		-- Their profile has not loaded, or failed to. Roblox will retry, but a wave of
		-- these on launch day is a fulfilment outage, and it used to be invisible: these
		-- paths only reached the server log. Reported through the same signal a granted
		-- purchase uses, so the dashboard shows it beside the successes.
		PurchaseService.PurchaseResolved:Fire(player, "Unknown", "NoData")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if data.PurchaseHistory[purchaseKey] then
		-- Already granted; this is a retry of an acknowledgement Roblox did not receive.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = devProductsByAssetId[receiptInfo.ProductId]
	if product == nil then
		-- A real purchase of something this build does not define — a product removed
		-- from Products/ after it had sold, or a dashboard id that never landed in the
		-- code. Roblox retries this forever and the player never receives it, so it has
		-- to be visible somewhere other than a server log nobody is reading.
		warn(`[PurchaseService] Receipt for unknown product id {receiptInfo.ProductId}`)
		PurchaseService.PurchaseResolved:Fire(player, tostring(receiptInfo.ProductId), "UnknownProduct")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local ok, granted = pcall(product.Grant, player)
	if not ok then
		warn(`[PurchaseService] Grant for "{product.Id}" errored: {granted}`)
		PurchaseService.PurchaseResolved:Fire(player, product.Id, "Failed")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if granted ~= true then
		PurchaseService.PurchaseResolved:Fire(player, product.Id, "Failed")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	--[[
		Recorded and *persisted* before acknowledging.

		The record alone was not enough, though the comment here used to claim it was:
		it went into the in-memory profile and waited for ProfileStore's own ~30-second
		autosave. A crash inside that window loses the record but not the charge, so
		Roblox's retry finds no history and grants a second time — or, if the grant
		itself was the thing that persisted, the player pays twice for one item. Forcing
		the save closes the window to the width of one UpdateAsync.

		Ordered before the acknowledgement for the same reason it always was: if the
		save fails we return NotProcessedYet and Roblox re-delivers, which is the outcome
		that costs the player nothing.
	]]
	data.PurchaseHistory[purchaseKey] = true
	DataService:MarkDirty(player)
	if not DataService:Save(player) then
		PurchaseService.PurchaseResolved:Fire(player, product.Id, "SaveFailed")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	PurchaseService.PurchaseResolved:Fire(player, product.Id, "Granted")

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseService:Start()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_processReceipt(receiptInfo)
	end

	-- Primed here rather than on the first shop opening, so the first player to look
	-- sees dashboard prices instead of the fallbacks.
	local warmList = {}
	for _, product in products do
		table.insert(warmList, product)
	end
	ProductInfo.Warm(warmList)

	--[[
		What the shop screen draws. Built from the same registry the prompt path uses,
		so a new file in Products/ appears in the UI with no client edit — and an
		unconfigured AssetId is reported as unavailable here rather than being offered
		and then refused after the player has already tried to buy it.
	]]
	Net.BindFunction("GetProductCatalogue", 2, function(player: Player)
		local FlagService = Loader.Get("FlagService")
		local open = FlagService:Get(player, "ShopEnabled") ~= false

		local rows = {}
		for _, product in products do
			-- Price and icon come from the Creator Dashboard, not from the module: the
			-- two drifted apart on six of seven products before this. ProductInfo never
			-- yields and falls back to product.RobuxPrice, so a rate-limited or offline
			-- lookup still returns a shop.
			local info = ProductInfo.Get(product)
			table.insert(rows, {
				Id = product.Id,
				Kind = product.Kind,
				DisplayName = product.DisplayName,
				Description = product.Description,
				RobuxPrice = info.Price,
				Icon = info.Icon,
				-- Sent Natural-quoted rather than scaled here. The client holds the
				-- physique class already, so it can rescale the moment a transformation
				-- lands instead of waiting for the next catalogue round trip — and both
				-- sides scale through MuscleClassConfig.ScaleTokens, which is the same
				-- function the grant goes through.
				TokenGrant = product.TokenGrant,
				Available = open and product.AssetId ~= 0,
				Owned = product.Kind == "Gamepass" and self:OwnsGamepass(player, product.AssetId),
			})
		end

		-- Sorted server-side so every client shows the same order. Dictionary
		-- iteration order is not stable, and a shop whose rows move between openings
		-- is one the player has to re-read every time.
		table.sort(rows, function(left, right)
			if left.Kind ~= right.Kind then
				return left.Kind < right.Kind
			end
			if left.RobuxPrice ~= right.RobuxPrice then
				return left.RobuxPrice < right.RobuxPrice
			end
			return left.Id < right.Id
		end)

		return rows
	end)

	Net.BindFunction("PromptProduct", 2, function(player: Player, productId: any)
		if type(productId) ~= "string" then
			return false, "Invalid request."
		end

		-- The kill switch. It stops *new* prompts only: a receipt that already exists
		-- is still fulfilled by _processReceipt, because a player who has been charged
		-- must get what they paid for whether or not the store is open.
		local FlagService = Loader.Get("FlagService")
		if FlagService:Get(player, "ShopEnabled") == false then
			return false, "The store is temporarily closed."
		end

		local product = products[productId]
		if product == nil then
			return false, "That item does not exist."
		end
		if product.AssetId == 0 then
			return false, "That item is not available yet."
		end

		if product.Kind == "Gamepass" then
			MarketplaceService:PromptGamePassPurchase(player, product.AssetId)
		else
			MarketplaceService:PromptProductPurchase(player, product.AssetId)
		end

		PurchaseService.ProductPrompted:Fire(player, product.Id)

		return true, nil
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(player: Player, gamePassId: number, wasPurchased: boolean)
			if not wasPurchased then
				for _, product in gamepasses do
					if product.AssetId == gamePassId then
						PurchaseService.PurchaseResolved:Fire(player, product.Id, "Declined")
					end
				end
				return
			end
			-- Bought just now, so whatever the cache last read is wrong.
			forgetOwnership(player, gamePassId)
			for _, product in gamepasses do
				if product.AssetId == gamePassId then
					product.Grant(player)
					PurchaseService.PurchaseResolved:Fire(player, product.Id, "Granted")
				end
			end
		end
	)

	-- The cache is keyed by Player, so it would otherwise hold a reference to everyone
	-- who has ever joined this server.
	Players.PlayerRemoving:Connect(function(player: Player)
		forgetOwnership(player, nil)
	end)

	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(function()
			self:ApplyGamepasses(player)
		end)
	end)
end

return PurchaseService
