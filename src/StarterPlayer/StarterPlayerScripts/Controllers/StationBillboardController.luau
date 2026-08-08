--!strict
--[[
	StationBillboardController — floating labels over training machines.

	The proximity prompt tells you a machine can be used and which key does it. This
	tells you whether it is worth using: which stat it trains, what rate you
	personally would get with your multipliers applied, whether you have the power to
	unlock it, and whether anyone is already on it.

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
-- How far above the machine the label floats.
local HEADROOM = 2.5

local StationBillboardController = {
	Name = "StationBillboardController",
	Priority = 6,
}

local ProfileController: any = nil

type Entry = {
	station: Instance,
	definition: EquipmentConfig.EquipmentDefinition,
	label: TextLabel,
	gui: BillboardGui,
}

local billboards: { [Instance]: Entry } = {}

function StationBillboardController:Init()
	ProfileController = Loader.Get("ProfileController")
end

--[[
	Where to float the label so it clears the machine rather than the one part it
	happens to be adorning — a pull-up rig's Base is its top bar, a bench's is the
	pad five studs lower.
]]
local function headroomOffset(station: Instance, adornee: BasePart): Vector3
	if station:IsA("Model") then
		local boundsCFrame, boundsSize = station:GetBoundingBox()
		local top = boundsCFrame.Position.Y + boundsSize.Y / 2
		return Vector3.new(0, (top - adornee.Position.Y) + HEADROOM, 0)
	end
	return Vector3.new(0, adornee.Size.Y / 2 + HEADROOM, 0)
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

	local adornee = EquipmentConfig.GetBase(station)
	if adornee == nil then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "StationLabel"
	gui.Adornee = adornee
	-- Four lines now: name, rate, what the stat buys you, and how to get on.
	gui.Size = UDim2.fromOffset(210, 90)
	gui.StudsOffsetWorldSpace = headroomOffset(station, adornee)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 70
	gui.Parent = adornee

	local panel = UI.Panel("Body", gui)
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundTransparency = 0.2

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 13

	billboards[station] = { station = station, definition = definition, label = label, gui = gui }
end

function StationBillboardController:_unbind(station: Instance)
	local entry = billboards[station]
	if entry ~= nil then
		entry.gui:Destroy()
		billboards[station] = nil
	end
end

--[[
	The third line: how to get on, or why you cannot. Occupancy is read straight off
	the attributes the server keeps on the station model.
]]
local function statusLine(entry: Entry): string
	local used = entry.station:GetAttribute(EquipmentConfig.OCCUPANCY_ATTRIBUTE)
	local capacity = entry.station:GetAttribute(EquipmentConfig.CAPACITY_ATTRIBUTE)

	if type(used) == "number" and type(capacity) == "number" and capacity > 0 then
		if used >= capacity then
			return `<font color="#FF5C5C">In use — {used}/{capacity}</font>`
		end
		if capacity > 1 then
			return `<font color="#8A93A8">Hold E to {entry.definition.ActionText} — {capacity - used}/{capacity} free</font>`
		end
	end

	return `<font color="#8A93A8">Hold E to {entry.definition.ActionText}</font>`
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
			local locationMultiplier = entry.station:GetAttribute("GainMultiplier")
			local zoneRate = if type(locationMultiplier) == "number" then locationMultiplier else 1
			local perSecond = definition.BaseGain
				* zoneRate
				* Formulas.MultiplierValue(level)
				/ definition.RepInterval

			-- The third line is what the stat is FOR. A player standing at the
			-- pull-up bar could previously read that it trains Back and how fast,
			-- and still have no idea what Back does to them.
			local effect = if statDefinition ~= nil
				then statDefinition.Effect(if data ~= nil then data.Stats else {})
				else ""

			entry.label.Text = `<b>{definition.DisplayName}</b>\n`
				.. `<font color="#{color:ToHex()}">{definition.StatId}</font>  `
				.. `+{NumberFormat.Format(perSecond)}/s\n`
				.. `<font color="#8A93A8">{effect}</font>\n`
				.. statusLine(entry)
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
