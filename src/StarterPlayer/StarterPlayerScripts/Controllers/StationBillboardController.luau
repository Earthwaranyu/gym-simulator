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
	warningFrame: Frame,
	warningText: TextLabel,
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
	gui.Size = UDim2.fromOffset(260, 105)
	gui.StudsOffsetWorldSpace = headroomOffset(station, adornee)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 80
	gui.Parent = adornee

	-- Container layout to hold warning circle on top and text panel below
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.BackgroundTransparency = 1
	container.Size = UDim2.fromScale(1, 1)
	container.Parent = gui

	local warningFrame = Instance.new("Frame")
	warningFrame.Name = "WarningBadge"
	warningFrame.AnchorPoint = Vector2.new(0.5, 0)
	warningFrame.Position = UDim2.fromScale(0.5, 0)
	warningFrame.Size = UDim2.fromOffset(36, 36)
	warningFrame.BackgroundColor3 = Color3.fromRGB(235, 75, 60)
	warningFrame.BackgroundTransparency = 0.05
	warningFrame.BorderSizePixel = 0
	warningFrame.Visible = false
	warningFrame.Parent = container

	local warningCorner = Instance.new("UICorner")
	warningCorner.CornerRadius = UDim.new(1, 0)
	warningCorner.Parent = warningFrame

	local warningStroke = Instance.new("UIStroke")
	warningStroke.Color = Color3.fromRGB(255, 255, 255)
	warningStroke.Thickness = 2
	warningStroke.Parent = warningFrame

	local warningText = UI.Label("ExclamationMark", warningFrame)
	warningText.Size = UDim2.fromScale(1, 1)
	warningText.Text = "!"
	warningText.Font = UI.Font.Heading
	warningText.TextSize = 24
	warningText.TextColor3 = Color3.fromRGB(255, 255, 255)
	warningText.TextXAlignment = Enum.TextXAlignment.Center
	warningText.TextYAlignment = Enum.TextYAlignment.Center

	local panel = UI.Panel("Body", container)
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.fromScale(0.5, 1)
	panel.Size = UDim2.new(1, 0, 1, -40)
	panel.BackgroundTransparency = 0.2

	local label = UI.Label("Text", panel)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextSize = 13

	billboards[station] = {
		station = station,
		definition = definition,
		label = label,
		warningFrame = warningFrame,
		warningText = warningText,
		gui = gui,
	}
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
		local statDisplayName = if statDefinition ~= nil
			then statDefinition.DisplayName
			else definition.StatId
		local color = if statDefinition ~= nil then statDefinition.Color else UI.Palette.Text

		local reqPowerAttribute = entry.station:GetAttribute("RequiredPower")
		local reqPower = if type(reqPowerAttribute) == "number"
			then reqPowerAttribute
			else definition.UnlockPower
		local requiredPower = math.max(reqPower, definition.UnlockPower)

		local owned = data ~= nil and data.OwnedEquipment[definition.Id] == true
		local unlocked = owned or power >= requiredPower

		-- Required-power stations carry the warning badge from the reference. Starter
		-- machines do not shout "warning" when there is no gate to warn about.
		entry.warningFrame.Visible = requiredPower > 0
		entry.warningFrame.BackgroundColor3 = Color3.fromRGB(235, 75, 60)

		local level = if data ~= nil then (data.MultiplierLevels[definition.StatId] or 0) else 0
		local locationMultiplier = entry.station:GetAttribute("GainMultiplier")
		local zoneRate = if type(locationMultiplier) == "number" then locationMultiplier else 1
		local perSecond = definition.BaseGain
			* zoneRate
			* Formulas.MultiplierValue(level)
			/ definition.RepInterval

		local reqLine = if requiredPower > 0
			then `<font color="#FF7B7B">Require : {NumberFormat.Format(requiredPower)}+ Power</font>\n`
			else ""

		if unlocked then
			entry.label.Text = `<b>{definition.DisplayName}</b>\n`
				.. reqLine
				.. `<font color="#{color:ToHex()}">+{NumberFormat.Format(perSecond)} {statDisplayName}</font>/s\n`
				.. statusLine(entry)
		else
			entry.label.Text = `<b>{definition.DisplayName}</b>\n`
				.. reqLine
				.. `<font color="#FF5C5C">Locked — {NumberFormat.Format(requiredPower)} total power needed</font>`
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
