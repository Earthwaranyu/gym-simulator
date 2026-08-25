--!strict
-- Selectable power-earned titles, replicated as Player attributes for nameplates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)

local TitleService = { Name = "TitleService", Priority = 65 }
local DataService: any = nil
local StatService: any = nil
local PurchaseService: any = nil

local function publish(player: Player, titleId: string)
	local title = RankConfig.GetById(titleId) or RankConfig.List[1]
	player:SetAttribute("TitleId", title.Id)
	player:SetAttribute("TitleName", title.DisplayName)
	player:SetAttribute("TitleColor", title.Color)
	player:SetAttribute("TitleGlow", title.Glow == true)
end

--[[
	Whether this player may wear this title. Yields for a bought title, because
	ownership is a live MarketplaceService answer rather than anything on the profile —
	the same call VipService:IsVip makes, and the reason both callers below run it off
	the main path.

	A power rank and a bought title are asked different questions, and RankConfig knows
	which is which; this only supplies the ownership answer.
]]
local function isUnlocked(player: Player, title: RankConfig.Rank): boolean
	return RankConfig.IsUnlocked(title.Id, StatService:GetTotalPower(player), function(productId)
		local product = PurchaseService:GetProduct(productId)
		return product ~= nil and PurchaseService:OwnsGamepass(player, product.AssetId)
	end)
end

function TitleService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	PurchaseService = Loader.Get("PurchaseService")
	Net.BindFunction("SelectTitle", 4, function(player: Player, titleId: any)
		if type(titleId) ~= "string" then
			return false, "Invalid title."
		end
		local title = RankConfig.GetById(titleId)
		local data = DataService:GetData(player)
		if title == nil or data == nil then
			return false, "That title does not exist."
		end
		if not isUnlocked(player, title) then
			return false,
				if title.RequiresGamepass ~= nil
					then `The {title.DisplayName} gamepass unlocks this title.`
					else `Reach {NumberFormat.Format(title.MinPower)} Power to unlock {title.DisplayName}.`
		end
		data.SelectedTitleId = title.Id
		DataService:MarkDirty(player)
		publish(player, title.Id)
		return true, `{title.DisplayName} title equipped.`
	end)
end

function TitleService:Start()
	local function loadTitle(player: Player, data: any)
		local selected = RankConfig.GetById(data.SelectedTitleId)
		if selected == nil then
			data.SelectedTitleId = RankConfig.List[1].Id
			DataService:MarkDirty(player)
			publish(player, data.SelectedTitleId)
			return
		end

		-- Published first, then verified. The ownership check yields, and a VIP whose
		-- plate is blank for a second while Roblox answers reads worse than one that
		-- shows the saved title and is corrected if it turns out to be wrong.
		publish(player, selected.Id)
		task.spawn(function()
			if isUnlocked(player, selected) then
				return
			end
			-- Demoted rather than kept: a refunded pass or a physique reset must not
			-- leave someone wearing a title they can no longer earn.
			data.SelectedTitleId = RankConfig.List[1].Id
			DataService:MarkDirty(player)
			publish(player, data.SelectedTitleId)
		end)
	end

	DataService.ProfileLoaded:Connect(loadTitle)
	-- Start hooks are scheduled independently. Catch a mock-store profile that loaded
	-- between DataService starting and this listener being connected.
	for _, player in Players:GetPlayers() do
		local data = DataService:GetData(player)
		if data ~= nil then
			loadTitle(player, data)
		end
	end
end

return TitleService
