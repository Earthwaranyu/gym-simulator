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
]]
function PurchaseService:OwnsGamepass(player: Player, assetId: number): boolean
	if assetId == 0 then
		return false
	end

	local ok, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, assetId)
	end)

	return ok and owns == true
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
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local purchaseKey = tostring(receiptInfo.PurchaseId)
	if data.PurchaseHistory[purchaseKey] then
		-- Already granted; this is a retry of an acknowledgement Roblox did not receive.
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local product = devProductsByAssetId[receiptInfo.ProductId]
	if product == nil then
		warn(`[PurchaseService] Receipt for unknown product id {receiptInfo.ProductId}`)
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

	-- Recorded before acknowledging, so a crash between the two costs the player
	-- nothing: the retry finds the record and returns PurchaseGranted.
	data.PurchaseHistory[purchaseKey] = true
	DataService:MarkDirty(player)

	PurchaseService.PurchaseResolved:Fire(player, product.Id, "Granted")

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

function PurchaseService:Start()
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return self:_processReceipt(receiptInfo)
	end

	Net.BindFunction("PromptProduct", 2, function(player: Player, productId: any)
		if type(productId) ~= "string" then
			return false, "Invalid request."
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
			for _, product in gamepasses do
				if product.AssetId == gamePassId then
					product.Grant(player)
					PurchaseService.PurchaseResolved:Fire(player, product.Id, "Granted")
				end
			end
		end
	)

	DataService.ProfileLoaded:Connect(function(player: Player)
		task.spawn(function()
			self:ApplyGamepasses(player)
		end)
	end)
end

return PurchaseService
