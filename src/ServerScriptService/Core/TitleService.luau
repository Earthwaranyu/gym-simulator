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

local function publish(player: Player, titleId: string)
	local title = RankConfig.GetById(titleId) or RankConfig.List[1]
	player:SetAttribute("TitleId", title.Id)
	player:SetAttribute("TitleName", title.DisplayName)
	player:SetAttribute("TitleColor", title.Color)
end

function TitleService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
	Net.BindFunction("SelectTitle", 4, function(player: Player, titleId: any)
		if type(titleId) ~= "string" then
			return false, "Invalid title."
		end
		local title = RankConfig.GetById(titleId)
		local data = DataService:GetData(player)
		if title == nil or data == nil then
			return false, "That title does not exist."
		end
		if StatService:GetTotalPower(player) < title.MinPower then
			return false, `Reach {NumberFormat.Format(title.MinPower)} Power to unlock {title.DisplayName}.`
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
		if selected == nil or StatService:GetTotalPower(player) < selected.MinPower then
			data.SelectedTitleId = RankConfig.List[1].Id
			DataService:MarkDirty(player)
		end
		publish(player, data.SelectedTitleId)
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
