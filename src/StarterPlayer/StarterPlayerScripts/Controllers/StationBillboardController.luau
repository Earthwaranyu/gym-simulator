--!strict
--[[
	StationBillboardController — floating labels over training machines.

	The proximity prompt tells you a machine can be used and which key does it. This
	tells you whether it is worth using: which stat it trains, what rate you
	personally would get with your multipliers applied, whether you have the power to
	unlock it, and whether anyone is already on it.

	Built client-side per tagged station, so they cost the server nothing and appear
	for machines added or streamed in later.

	The sign is a fixed size and stays one. It was briefly sized against the camera so
	that it would read large from across the gym and shrink as you walked in, and that
	is worth writing down as a dead end: holding a billboard to a chosen share of the
	screen means fighting perspective every frame, and the result read as wrong even
	when the numbers were right — a sign that grows as you back away does not behave
	like anything else in the world, so the eye files it as a bug. Perspective alone
	does the job, and a machine across the room is found by its glyph and its colour.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local TokenMultiplierConfig = require(ReplicatedStorage.Modules.TokenMultiplierConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Icons = require(ReplicatedStorage.Modules.Icons)

local REFRESH_SECONDS = 1
-- How far above the machine the label floats.
local HEADROOM = 2.5
local AREA_INFO_ANCHOR = "AreaInfoAnchor"
-- The muscle glyph above the text. Sized to read from the far side of a court, which
-- is further than the words ever do.
local ICON_SIZE = 52
-- Amber, matching the reference's requirement line. Bright enough to survive the black
-- outline at a distance, and distinct from every stat colour so the gate never reads
-- as part of the muscle's identity.
local REQUIREMENT_COLOR = Color3.fromRGB(255, 181, 49)

-- The sign, at a fixed size. It gets smaller with distance the way everything else in
-- the world does, and nothing in here changes it per frame.
local SIGN_WIDTH = 340
local SIGN_HEIGHT = 212
-- What is left for the text once the glyph has taken its share off the top.
local BODY_HEIGHT = SIGN_HEIGHT - ICON_SIZE
-- Further than the old 140, so a machine on the far side of the gym still announces
-- itself; past this it is a handful of pixels and not worth drawing.
local SIGN_MAX_DISTANCE = 300

local StationBillboardController = {
	Name = "StationBillboardController",
	Priority = 6,
}

local ProfileController: any = nil

type Entry = {
	station: Instance,
	occupancySource: Instance,
	definition: EquipmentConfig.EquipmentDefinition,
	-- One label per line rather than one rich-text block, so each line owns its own
	-- size. A single block can only be one size, and the reference sign works because
	-- the machine's name is twice the height of the caption above the requirement.
	multiplier: TextLabel,
	name: TextLabel,
	requiresCaption: TextLabel,
	requirement: TextLabel,
	rate: TextLabel,
	status: TextLabel,
	gui: BillboardGui,
}

--[[
	Every line on the sign is outlined text on nothing.

	It used to sit on a rounded translucent panel, and against a bright sky that panel
	was a cream slab that hid the machine behind it and washed out its own text. The
	reference has no panel at all: the words float in the world and stay readable over
	anything because each glyph carries a hard black outline. So the outline is what
	does the work here, and there is no background to fight the world for contrast.

]]
local function signLabel(name: string, parent: GuiObject, order: number, size: number): TextLabel
	local label = UI.Label(name, parent)
	label.Size = UDim2.new(1, 0, 0, size + 6)
	label.LayoutOrder = order
	label.BackgroundTransparency = 1
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextSize = size
	label.Font = UI.Font.Heading
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.TextStrokeTransparency = 0
	return label
end

local billboards: { [Instance]: { Entry } } = {}

function StationBillboardController:Init()
	ProfileController = Loader.Get("ProfileController")
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

	local entries: { Entry } = {}
	-- One sign per station model. Courts hold a single machine now, so this loop is a
	-- one-iteration formality kept because occupancy is still read per copy.
	for _, copy in { station } do
		local authoredAnchor = station:FindFirstChild(AREA_INFO_ANCHOR, true)
		local adornee = if authoredAnchor ~= nil and authoredAnchor:IsA("BasePart")
			then authoredAnchor
			else EquipmentConfig.GetBase(station)
		if adornee == nil then
			continue
		end

		local gui = Instance.new("BillboardGui")
		gui.Name = "StationLabel"
		gui.Adornee = adornee
		gui.Size = UDim2.fromOffset(SIGN_WIDTH, SIGN_HEIGHT)
		-- An authored anchor is already placed where the sign belongs; anything else has
		-- to clear the machine's own bounding box.
		gui.StudsOffsetWorldSpace = if adornee.Name == AREA_INFO_ANCHOR
			then Vector3.zero
			else UI.HeadroomOffset(copy, adornee, HEADROOM)
		-- Half a sign height, which is the offset that parks the sign's bottom edge on the
		-- anchor point rather than centring the sign over it.
		gui.ExtentsOffsetWorldSpace = Vector3.new(0, 0.5, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = SIGN_MAX_DISTANCE
		gui.Parent = adornee

		local container = Instance.new("Frame")
		container.Name = "Container"
		container.BackgroundTransparency = 1
		container.Size = UDim2.fromScale(1, 1)
		container.Parent = gui

		-- The muscle glyph, centred over the sign. It is the part of the sign that reads
		-- from across the map: the multiplier and the name need you close enough to read
		-- text, the icon tells you which muscle this court is from any distance.
		local statDefinition = StatConfig.Get(definition.StatId)
		local statColor = if statDefinition ~= nil then statDefinition.Color else UI.Palette.Text
		local iconHolder = Instance.new("Frame")
		iconHolder.Name = "StatIcon"
		iconHolder.AnchorPoint = Vector2.new(0.5, 0)
		iconHolder.Position = UDim2.fromScale(0.5, 0)
		-- Height-driven with the width following, so the glyph stays square on a sign
		-- whose own shape is not.
		iconHolder.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Parent = container
		if statDefinition ~= nil and Icons.Has(statDefinition.Icon) then
			Icons.Draw(statDefinition.Icon, iconHolder, statColor, UI.Palette.Surface)
		end

		-- The lines below the glyph, stacked by a list layout so no line has to know
		-- where the one above it ended. Hidden lines cost no height, so shedding detail
		-- with distance also makes the sign physically smaller.
		local body = Instance.new("Frame")
		body.Name = "Body"
		body.AnchorPoint = Vector2.new(0.5, 0)
		body.Position = UDim2.new(0.5, 0, 0, ICON_SIZE)
		body.Size = UDim2.new(1, 0, 0, BODY_HEIGHT)
		body.BackgroundTransparency = 1
		body.Parent = container

		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Vertical
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = body

		local multiplier = signLabel("Multiplier", body, 1, 24)
		local name = signLabel("Name", body, 2, 28)
		local requiresCaption = signLabel("RequiresCaption", body, 3, 14)
		local requirement = signLabel("Requirement", body, 4, 20)
		local rate = signLabel("Rate", body, 5, 15)
		local status = signLabel("Status", body, 6, 14)

		table.insert(entries, {
			station = station,
			occupancySource = copy,
			definition = definition,
			multiplier = multiplier,
			name = name,
			requiresCaption = requiresCaption,
			requirement = requirement,
			rate = rate,
			status = status,
			gui = gui,
		})
	end

	billboards[station] = entries
end

function StationBillboardController:_unbind(station: Instance)
	local entries = billboards[station]
	if entries ~= nil then
		for _, entry in entries do
			entry.gui:Destroy()
		end
		billboards[station] = nil
	end
end

--[[
	The bottom line: how to get on, or why you cannot. Occupancy is read straight off
	the attributes the server keeps on the station model. Returns the colour with the
	text now that each line is its own label rather than a rich-text span.
]]
local function statusLine(entry: Entry): (string, Color3)
	local used = entry.occupancySource:GetAttribute(EquipmentConfig.OCCUPANCY_ATTRIBUTE)
	local capacity = entry.occupancySource:GetAttribute(EquipmentConfig.CAPACITY_ATTRIBUTE)

	if type(used) == "number" and type(capacity) == "number" and capacity > 0 then
		if used >= capacity then
			return `IN USE — {used}/{capacity}`, UI.Palette.Danger
		end
		return `HOLD E TO {string.upper(entry.definition.ActionText)}`, Color3.fromRGB(235, 238, 245)
	end

	return `HOLD E TO {string.upper(entry.definition.ActionText)}`, Color3.fromRGB(235, 238, 245)
end

function StationBillboardController:_refresh()
	local data = ProfileController:Get()

	for _, entries in billboards do
		for _, entry in entries do
			local definition = entry.definition
			local statDefinition = StatConfig.Get(definition.StatId)
			local statDisplayName = if statDefinition ~= nil
				then statDefinition.DisplayName
				else definition.StatId
			local color = if statDefinition ~= nil then statDefinition.Color else UI.Palette.Text

			local reqStatAttribute = entry.station:GetAttribute("RequiredStat")
			local reqStat = if type(reqStatAttribute) == "number"
				then reqStatAttribute
				else definition.UnlockPower
			local requiredStat = math.max(reqStat, definition.UnlockPower)
			local relevantStat = if data ~= nil then (data.Stats[definition.StatId] or 0) else 0

			local owned = data ~= nil and data.OwnedEquipment[definition.Id] == true
			local unlocked = owned or relevantStat >= requiredStat

			local level = if data ~= nil then (data.MultiplierLevels[definition.StatId] or 0) else 0
			local locationMultiplier = entry.station:GetAttribute("GainMultiplier")
			local zoneRate = if type(locationMultiplier) == "number" then locationMultiplier else 1
			local totalPerSecond = Formulas.MachineTrainingRate(
				definition.BaseGain / definition.RepInterval,
				zoneRate
			) * TokenMultiplierConfig.Multiplier(level)

			-- Reads top to bottom as the reference sign does: what this place multiplies,
			-- what the machine is, then the gate in brackets under a REQUIRES caption.
			entry.multiplier.Text = `×{NumberFormat.Format(zoneRate)}`
			entry.multiplier.TextColor3 = Color3.fromRGB(255, 255, 255)

			entry.name.Text = `[{definition.DisplayName}]`
			entry.name.TextColor3 = color

			-- A starter machine gets no REQUIRES block at all rather than a line saying it
			-- has no requirement: two fewer lines of nothing on the signs a new player is
			-- standing among, and the caption keeps its meaning when it does appear.
			entry.requiresCaption.Visible = requiredStat > 0
			entry.requirement.Visible = requiredStat > 0
			if requiredStat > 0 then
				entry.requiresCaption.Text = "REQUIRES"
				entry.requiresCaption.TextColor3 = Color3.fromRGB(235, 238, 245)
				entry.requirement.Text = `[{NumberFormat.Format(requiredStat)}+ {statDisplayName}]`
				entry.requirement.TextColor3 = if unlocked then REQUIREMENT_COLOR else UI.Palette.Danger
			end

			if unlocked then
				entry.rate.Text = `+{NumberFormat.Format(totalPerSecond)} {string.upper(statDisplayName)}/SEC`
				entry.rate.TextColor3 = color
				local statusText, statusColor = statusLine(entry)
				entry.status.Text = statusText
				entry.status.TextColor3 = statusColor
			else
				entry.rate.Text = "LOCKED"
				entry.rate.TextColor3 = UI.Palette.Danger
				entry.status.Text =
					`NEEDS {NumberFormat.Format(requiredStat)} {string.upper(statDisplayName)}`
				entry.status.TextColor3 = UI.Palette.Danger
			end
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
			-- A failure in a cosmetic loop must not stop the loop.
			local ok, err = pcall(function()
				self:_refresh()
			end)
			if not ok then
				warn(`[StationBillboardController] {err}`)
			end
		end
	end)
end

return StationBillboardController
