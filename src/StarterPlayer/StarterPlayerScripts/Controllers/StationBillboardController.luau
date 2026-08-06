--!strict
--[[
	StationBillboardController — floating labels over training machines.

	With training automatic and no prompt to press, a machine has nothing to explain
	itself. These labels are what tell a player which stat a machine trains, how fast,
	and whether they are allowed to use it yet — the job the interaction prompt used to
	do before auto-training replaced it.

	Built client-side per tagged station, so they cost the server nothing and appear
	for machines added or streamed in later.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local REFRESH_SECONDS = 1

local StationBillboardController = {
	Name = "StationBillboardController",
	Priority = 6,
}

local ProfileController: any = nil

type Entry = {
	definition: EquipmentConfig.EquipmentDefinition,
	label: TextLabel,
	gui: BillboardGui,
}

local billboards: { [Instance]: Entry } = {}

function StationBillboardController:Init()
	ProfileController = Loader.Get("ProfileController")
end

local function findAdornee(station: Instance): BasePart?
	if station:IsA("BasePart") then
		return station
	end
	if station:IsA("Model") then
		local primary = station.PrimaryPart
		if primary ~= nil then
			return primary
		end
		return station:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function StationBillboardController:_bind(station: Instance)
	if billboards[station] ~= nil then
		return
	end

	local definition, reason = EquipmentConfig.Resolve(station)
	if definition == nil then
		warn(`[StationBillboardController] Ignoring {station:GetFullName()}: {reason}`)
		return
	end

	local adornee = findAdornee(station)
	if adornee == nil then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "StationLabel"
	gui.Adornee = adornee
	gui.Size = UDim2.fromOffset(200, 54)
	gui.StudsOffsetWorldSpace = Vector3.new(0, adornee.Size.Y / 2 + 2.5, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 60
	gui.Parent = adornee

	local panel = UI.Panel("Body", gui)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundTransparency = 0.2

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 13

	billboards[station] = { definition = definition, label = label, gui = gui }
end

function StationBillboardController:_unbind(station: Instance)
	local entry = billboards[station]
	if entry ~= nil then
		entry.gui:Destroy()
		billboards[station] = nil
	end
end

function StationBillboardController:_refresh()
	local data = ProfileController:Get()

	local power = 0
	if data ~= nil then
		power = Formulas.TotalPower(data.Stats)
	end

	for _, entry in billboards do
		local definition = entry.definition
		local statDefinition = StatConfig.Get(definition.StatId)
		local color = if statDefinition ~= nil then statDefinition.Color else UI.Palette.Text

		local owned = data ~= nil and data.OwnedEquipment[definition.Id] == true
		local unlocked = owned or power >= definition.UnlockPower

		if unlocked then
			-- Show the rate the player would actually get, multipliers included.
			local level = if data ~= nil then (data.MultiplierLevels[definition.StatId] or 0) else 0
			local perSecond = definition.BaseGain * Formulas.MultiplierValue(level) / definition.RepInterval

			entry.label.Text = `<b>{definition.DisplayName}</b>\n`
				.. `<font color="#{color:ToHex()}">{definition.StatId}</font>  `
				.. `+{NumberFormat.Format(perSecond)}/s`
		else
			entry.label.Text = `<b>{definition.DisplayName}</b>\n`
				.. `<font color="#FF5C5C">Locked — {NumberFormat.Format(definition.UnlockPower)} power</font>`
		end
	end
end

function StationBillboardController:Start()
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		self:_bind(station)
	end

	CollectionService:GetInstanceAddedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_bind(station)
	end)

	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_unbind(station)
	end)

	self:_refresh()

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			self:_refresh()
		end
	end)
end

return StationBillboardController
