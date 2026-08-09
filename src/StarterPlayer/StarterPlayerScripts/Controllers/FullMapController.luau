--!strict
--[[
	FullMapController — the dedicated, interactive city map.

	The old full map lived inside MenuController's vertical ScrollingFrame. Its own
	zoomable ScrollingFrame therefore competed with the page for every mouse-wheel
	gesture: zooming out could scroll the page, and scrolling the page could move the
	map. This controller owns a separate ScreenGui with no page scroll at all. Wheel,
	drag and touch input have exactly one possible destination: the map canvas.

	Selecting a pin never performs an action immediately. It opens a persistent detail
	panel with two honest choices:

	  * Track is free and creates the existing world waypoint.
	  * Teleport is visibly locked behind Fast Travel and is still revalidated by the
	    server, including ownership, power, combat state and destination existence.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local Icons = require(ReplicatedStorage.Modules.Icons)
local MapRender = require(ReplicatedStorage.Modules.MapRender)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

type Destination = MapRender.Destination

local FullMapController = {
	Name = "FullMapController",
	Priority = 8,
}

FullMapController.Changed = Signal.new()

local PANEL_SIZE = Vector2.new(980, 620)
local HEADER_HEIGHT = 48
local CONTENT_GAP = 12
local SIDEBAR_WIDTH = 250
local MAP_ASPECT = 1.19
local MIN_ZOOM = 1
local MAX_ZOOM = 4
local ZOOM_STEP = 1.25
local PIN_SIZE = 30
local SELECTED_PIN_SIZE = 32
local RECOMMENDED_PIN_SIZE = 36

local MAP_PAPER = MapRender.Paper
local MAP_INK = MapRender.Ink

local player = Players.LocalPlayer
local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local content: Frame
local isOpen = false
local hasFastTravel = false
local selectedDestination: string? = nil
local destinations: { Destination } = {}
local mapFeatures: { MapRender.Feature } = {}
local mapZoom = 1
local mapCenter = Vector2.new(0.5, 0.5)
local renderedPower = 0
local recommendedDestination: string? = nil

local function toast(message: string?)
	if ToastController ~= nil and type(message) == "string" and message ~= "" then
		ToastController:Show(message)
	end
end

local function addCorner(parent: GuiObject, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addBorder(
	parent: GuiObject,
	color: Color3,
	transparency: number?,
	thickness: number?
): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Transparency = transparency or 0
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

local function destinationLabel(destination: Destination): (string, Color3)
	local equipment = EquipmentConfig.Get(destination.EquipmentId)
	local zone = ZoneConfig.Get(destination.ZoneId)
	local stat = StatConfig.Get(destination.StatId)
	local equipmentName = if equipment ~= nil then equipment.DisplayName else destination.EquipmentId
	local zoneName = if zone ~= nil then zone.DisplayName else destination.LocationName
	local color = if stat ~= nil then stat.Color else UI.Palette.Accent
	return `{equipmentName} · {zoneName}`, color
end

-- Ground venues use their environment id, while skyline venues deliberately have a
-- unique environment id so their barriers can be controlled independently. Their
-- human-facing location name still starts with the neighbourhood, so removing the
-- trailing "<Muscle> Gym" reunites street and skyline pins into one map cluster.
local function destinationCluster(destination: Destination): string
	if destination.ZoneId == "Garage" then
		return "Hub"
	end

	local suffix = ` {destination.StatId} Gym`
	if string.sub(destination.LocationName, -#suffix) == suffix then
		return string.sub(destination.LocationName, 1, #destination.LocationName - #suffix)
	end
	return destination.EnvironmentId
end

local function statOrder(statId: string): number
	for index, definition in StatConfig.List do
		if definition.Id == statId then
			return index
		end
	end
	return #StatConfig.List + 1
end

function FullMapController:Init()
	ProfileController = Loader.Get("ProfileController")
	ToastController = Loader.Get("ToastController")
end

function FullMapController:_fetchMap()
	destinations, mapFeatures = MapRender.Fetch()
end

function FullMapController:_fetchTravelAccess()
	local ok, access = pcall(function()
		return Net.Function("GetTravelAccess"):InvokeServer()
	end)
	if ok and type(access) == "table" then
		hasFastTravel = access.HasFastTravel == true
	end
end

function FullMapController:_promptFastTravel()
	local ok, message = Net.Function("PromptProduct"):InvokeServer("FastTravel")
	if not ok then
		toast(message or "Fast Travel is unavailable right now.")
	end
end

function FullMapController:_track(destination: Destination)
	local label, color = destinationLabel(destination)
	local WaypointController = Loader.Get("WaypointController")
	WaypointController:SetTarget(destination.Position, label, color)
	toast(`Tracking {label} — follow the arrow`)
	self:Close()
end

function FullMapController:_teleport(destination: Destination)
	-- The client lock is presentation only. TravelService repeats every check and is
	-- the sole authority that can move the character.
	local ok, message = Net.Function("Travel"):InvokeServer(destination.Id)
	if ok then
		toast(message)
		self:Close()
		return
	end

	if message == "NO_FAST_TRAVEL" then
		hasFastTravel = false
		toast("Fast Travel gamepass required. You can still track this location for free.")
		self:_render()
		return
	end

	toast(message)
end

function FullMapController:_recommend(power: number, stats: { [string]: number }): Destination?
	-- A single recommendation is more useful than making all currently unlocked pins
	-- shout at once. Train the weakest muscle at the best multiplier the player's total
	-- Power can enter; ties follow the stable five-stat display order.
	local weakest = StatConfig.List[1]
	local weakestValue = math.huge
	for _, definition in StatConfig.List do
		local value = Formulas.SanitizeStat(stats[definition.Id] or 0)
		if value < weakestValue then
			weakest = definition
			weakestValue = value
		end
	end
	if weakest == nil then
		return nil
	end

	local best: Destination? = nil
	for _, destination in destinations do
		if
			destination.StatId == weakest.Id
			and power >= destination.RequiredPower
			and (best == nil or destination.GainMultiplier > best.GainMultiplier)
		then
			best = destination
		end
	end
	return best
end

function FullMapController:_sideButton(
	parent: GuiObject,
	name: string,
	text: string,
	position: UDim2,
	color: Color3,
	enabled: boolean,
	onClick: () -> ()
): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.Position = position
	button.Size = UDim2.new(1, -20, 0, 44)
	button.BackgroundColor3 = color
	button.BackgroundTransparency = if enabled then 0 else 0.55
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Active = enabled
	button.Font = UI.Font.Heading
	button.TextSize = 14
	button.TextColor3 = if enabled then UI.Palette.CartoonInk else UI.Palette.TextMuted
	button.Text = text
	button.Parent = parent
	addCorner(button, 9)
	addBorder(button, if enabled then UI.Palette.CartoonInk else UI.Palette.GlassStroke, 0.25, 2)

	if enabled then
		UI.Pressable(button, { PressScale = 0.96, HoverScale = 1.015 })
		button.Activated:Connect(onClick)
	end
	return button
end

function FullMapController:_renderSidebar(parent: Frame, power: number)
	local destination = if selectedDestination ~= nil
		then MapRender.GetDestination(selectedDestination)
		else nil

	local heading = UI.Label("Heading", parent)
	heading.Position = UDim2.fromOffset(12, 10)
	heading.Size = UDim2.new(1, -24, 0, 20)
	heading.Font = UI.Font.Heading
	heading.TextSize = 12
	heading.TextColor3 = UI.Palette.TextMuted
	heading.Text = if destination ~= nil and destination.Id == recommendedDestination
		then "RECOMMENDED FOR YOUR BUILD"
		else "SELECTED LOCATION"

	if destination == nil then
		local empty = UI.Label("Empty", parent)
		empty.Position = UDim2.fromOffset(12, 42)
		empty.Size = UDim2.new(1, -24, 0, 80)
		empty.TextWrapped = true
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "Select a coloured circle on the map."
		return
	end

	local stat = StatConfig.Get(destination.StatId)
	local equipment = EquipmentConfig.Get(destination.EquipmentId)
	local zone = ZoneConfig.Get(destination.ZoneId)
	if stat == nil or equipment == nil or zone == nil then
		return
	end

	local iconBubble = Instance.new("Frame")
	iconBubble.Name = "StatIcon"
	iconBubble.Position = UDim2.fromOffset(12, 38)
	iconBubble.Size = UDim2.fromOffset(54, 54)
	iconBubble.BackgroundColor3 = stat.Color:Lerp(UI.Palette.CartoonInk, 0.68)
	iconBubble.BorderSizePixel = 0
	iconBubble.Parent = parent
	addCorner(iconBubble, 27)
	addBorder(iconBubble, stat.Color, 0.1, 2)

	local iconPadding = Instance.new("UIPadding")
	iconPadding.PaddingTop = UDim.new(0, 10)
	iconPadding.PaddingBottom = UDim.new(0, 10)
	iconPadding.PaddingLeft = UDim.new(0, 10)
	iconPadding.PaddingRight = UDim.new(0, 10)
	iconPadding.Parent = iconBubble
	Icons.Draw(stat.Icon, iconBubble, stat.Color, UI.Palette.CartoonInk)

	local machine = UI.Label("Machine", parent)
	machine.Position = UDim2.fromOffset(76, 40)
	machine.Size = UDim2.new(1, -88, 0, 24)
	machine.Font = UI.Font.Heading
	machine.TextSize = 15
	machine.TextColor3 = UI.Palette.Text
	machine.TextTruncate = Enum.TextTruncate.AtEnd
	machine.Text = string.upper(equipment.DisplayName)

	local muscle = UI.Label("Muscle", parent)
	muscle.Position = UDim2.fromOffset(76, 66)
	muscle.Size = UDim2.new(1, -88, 0, 18)
	muscle.Font = UI.Font.Heading
	muscle.TextSize = 12
	muscle.TextColor3 = stat.Color
	muscle.Text = `{string.upper(stat.DisplayName)} · ×{NumberFormat.Format(destination.GainMultiplier)}`

	local location = UI.Label("Location", parent)
	location.Position = UDim2.fromOffset(12, 108)
	location.Size = UDim2.new(1, -24, 0, 38)
	location.Font = UI.Font.Heading
	location.TextSize = 13
	location.TextWrapped = true
	location.TextColor3 = UI.Palette.Text
	location.Text = `{destination.LocationName}\n<font color="#8A93A8">{destination.LocationTagline}</font>`

	local perSecond = (equipment.BaseGain / equipment.RepInterval) * destination.GainMultiplier
	local rate = UI.Label("Rate", parent)
	rate.Position = UDim2.fromOffset(12, 158)
	rate.Size = UDim2.new(1, -24, 0, 42)
	rate.Font = UI.Font.Numeric
	rate.TextSize = 25
	rate.TextColor3 = stat.Color
	rate.Text = `+{NumberFormat.Format(perSecond)}/SEC`

	local access = if destination.AccessKind == "Sky"
		then `SKY DECK · {math.round(destination.Position.Y)} STUDS`
		elseif destination.FloorIndex > 1 then `FLOOR {destination.FloorIndex} INTERIOR`
		else "STREET LEVEL"
	local accessLabel = UI.Label("Access", parent)
	accessLabel.Position = UDim2.fromOffset(12, 204)
	accessLabel.Size = UDim2.new(1, -24, 0, 18)
	accessLabel.Font = UI.Font.Heading
	accessLabel.TextSize = 11
	accessLabel.TextColor3 = UI.Palette.TextMuted
	accessLabel.Text = access

	local shortfall = destination.RequiredPower - power
	local powerLabel = UI.Label("Power", parent)
	powerLabel.Position = UDim2.fromOffset(12, 230)
	powerLabel.Size = UDim2.new(1, -24, 0, 44)
	powerLabel.Font = UI.Font.Heading
	powerLabel.TextSize = 12
	powerLabel.TextWrapped = true
	if shortfall > 0 then
		powerLabel.TextColor3 = UI.Palette.Danger
		powerLabel.Text = `POWER LOCKED\nNEED {NumberFormat.Format(shortfall)} MORE`
	else
		powerLabel.TextColor3 = UI.Palette.Vital
		powerLabel.Text = `POWER UNLOCKED\n{NumberFormat.Format(destination.RequiredPower)} REQUIRED`
	end

	local rule = Instance.new("Frame")
	rule.Position = UDim2.fromOffset(12, 286)
	rule.Size = UDim2.new(1, -24, 0, 2)
	rule.BackgroundColor3 = UI.Palette.GlassStroke
	rule.BackgroundTransparency = 0.55
	rule.BorderSizePixel = 0
	rule.Parent = parent

	local actionHint = UI.Label("ActionHint", parent)
	actionHint.Position = UDim2.fromOffset(12, 302)
	actionHint.Size = UDim2.new(1, -24, 0, 34)
	actionHint.TextWrapped = true
	actionHint.TextSize = 11
	actionHint.TextColor3 = UI.Palette.TextMuted
	actionHint.Text = "Track is always free. Teleport requires Fast Travel and enough Power."

	self:_sideButton(parent, "Track", "TRACK", UDim2.new(0, 10, 1, -108), stat.Color, true, function()
		self:_track(destination)
	end)

	if not hasFastTravel then
		self:_sideButton(
			parent,
			"TeleportLocked",
			"LOCKED · GET FAST TRAVEL",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			true,
			function()
				self:_promptFastTravel()
			end
		)
	else
		self:_sideButton(
			parent,
			"Teleport",
			if shortfall > 0 then "LOCKED · NEED MORE POWER" else "TELEPORT",
			UDim2.new(0, 10, 1, -54),
			UI.Palette.Token,
			shortfall <= 0,
			function()
				self:_teleport(destination)
			end
		)
	end
end

function FullMapController:_render()
	if not isOpen then
		return
	end

	self:_fetchMap()
	local data = ProfileController:Get()
	local stats = if data ~= nil then data.Stats else {}
	local power = Formulas.TotalPower(stats)
	renderedPower = power
	local recommendation = self:_recommend(power, stats)
	recommendedDestination = if recommendation ~= nil then recommendation.Id else nil
	if selectedDestination == nil or MapRender.GetDestination(selectedDestination) == nil then
		selectedDestination = recommendedDestination
	end

	content:ClearAllChildren()

	local board = Instance.new("Frame")
	board.Name = "MapBoard"
	board.Size = UDim2.new(1, -SIDEBAR_WIDTH - CONTENT_GAP, 1, 0)
	board.BackgroundColor3 = Color3.fromRGB(20, 24, 25)
	board.BorderSizePixel = 0
	board.ClipsDescendants = true
	board.Parent = content
	addCorner(board, 10)
	addBorder(board, UI.Palette.GlassStroke, 0.45, 2)

	local sidebar = UI.Panel("Destination", content)
	sidebar.AnchorPoint = Vector2.new(1, 0)
	sidebar.Position = UDim2.fromScale(1, 0)
	sidebar.Size = UDim2.new(0, SIDEBAR_WIDTH, 1, 0)
	sidebar.BackgroundTransparency = 0.02
	self:_renderSidebar(sidebar, power)

	if #destinations == 0 then
		local loading = UI.Label("Loading", board)
		loading.Size = UDim2.fromScale(1, 1)
		loading.TextXAlignment = Enum.TextXAlignment.Center
		loading.TextColor3 = UI.Palette.TextMuted
		loading.Text = "MAPPING THE CITY…"
		return
	end

	local bounds = MapRender.Bounds(mapFeatures, destinations, MAP_ASPECT)
	local project = MapRender.Project(bounds)

	-- CanvasGroup is the clipping boundary. Unlike a plain Frame it also clips rotated
	-- road/building features reliably, so zoomed geometry cannot paint over the sidebar.
	local viewport = Instance.new("CanvasGroup")
	viewport.Name = "Viewport"
	viewport.Active = true
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundColor3 = Color3.fromRGB(20, 24, 25)
	viewport.BorderSizePixel = 0
	viewport.ClipsDescendants = true
	viewport.Parent = board

	local canvas = Instance.new("Frame")
	canvas.Name = "MapCanvas"
	canvas.Size = UDim2.fromScale(mapZoom, mapZoom)
	canvas.BackgroundColor3 = MAP_PAPER
	canvas.BorderSizePixel = 0
	canvas:SetAttribute("Zoom", mapZoom)
	canvas.Parent = viewport

	local features = Instance.new("Frame")
	features.Name = "Features"
	features.Size = UDim2.fromScale(1, 1)
	features.BackgroundTransparency = 1
	features.ZIndex = 1
	features.Parent = canvas
	MapRender.DrawFeatures(features, mapFeatures, bounds)

	-- The full map is deliberately moodier than the minimap. This quiet overlay keeps
	-- the complete street/building context visible without letting it compete with the
	-- one recommended training pin drawn above it.
	local mapShade = Instance.new("Frame")
	mapShade.Name = "MapShade"
	mapShade.Size = UDim2.fromScale(1, 1)
	mapShade.BackgroundColor3 = Color3.fromRGB(10, 14, 22)
	mapShade.BackgroundTransparency = 0.3
	mapShade.BorderSizePixel = 0
	mapShade.ZIndex = 10
	mapShade.Parent = canvas

	local pins = Instance.new("Frame")
	pins.Name = "Pins"
	pins.Size = UDim2.fromScale(1, 1)
	pins.BackgroundTransparency = 1
	pins.ZIndex = 20
	pins.Parent = canvas

	local hub = UI.Label("Hub", pins)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(72, 18)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.Font = UI.Font.Heading
	hub.TextSize = 10
	hub.TextColor3 = Color3.fromRGB(0, 118, 160)
	hub.Text = "◆ SPAWN"
	hub.ZIndex = 24

	local unlockedCount = 0
	local pinRecords: { [string]: { Button: TextButton, Stroke: UIStroke, Recommended: boolean } } = {}
	local clusterMembers: { [string]: { Destination } } = {}
	for _, destination in destinations do
		local key = destinationCluster(destination)
		local members = clusterMembers[key]
		if members == nil then
			members = {}
			clusterMembers[key] = members
		end
		table.insert(members, destination)
	end

	local pinPositions: { [string]: UDim2 } = {}
	for _, members in clusterMembers do
		table.sort(members, function(a, b)
			local aOrder = statOrder(a.StatId)
			local bOrder = statOrder(b.StatId)
			if aOrder ~= bOrder then
				return aOrder < bOrder
			end
			if a.GainMultiplier ~= b.GainMultiplier then
				return a.GainMultiplier < b.GainMultiplier
			end
			return a.Id < b.Id
		end)

		local sum = Vector3.zero
		for _, destination in members do
			sum += destination.Position
		end
		local centre = sum / #members
		local projectedCentre = project(centre.X, centre.Z)
		local radius = if #members == 1 then 0 else 18 + #members * 2.6
		for index, destination in members do
			local angle = math.rad(-90 + (index - 1) * 360 / #members)
			local offset = Vector2.new(math.cos(angle), math.sin(angle)) * radius
			pinPositions[destination.Id] = UDim2.new(
				projectedCentre.X.Scale,
				projectedCentre.X.Offset + offset.X,
				projectedCentre.Y.Scale,
				projectedCentre.Y.Offset + offset.Y
			)
		end
	end

	for _, destination in destinations do
		local stat = StatConfig.Get(destination.StatId)
		if stat == nil then
			continue
		end
		local unlocked = power >= destination.RequiredPower
		if unlocked then
			unlockedCount += 1
		end
		local selected = selectedDestination == destination.Id
		local recommended = recommendedDestination == destination.Id
		local pin = Instance.new("TextButton")
		pin.Name = destination.Id
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = pinPositions[destination.Id]
		pin.Size = UDim2.fromOffset(
			if recommended then RECOMMENDED_PIN_SIZE elseif selected then SELECTED_PIN_SIZE else PIN_SIZE,
			if recommended then RECOMMENDED_PIN_SIZE elseif selected then SELECTED_PIN_SIZE else PIN_SIZE
		)
		pin.BackgroundColor3 = if recommended
			then stat.Color
			elseif unlocked then stat.Color:Lerp(UI.Palette.Glass, 0.48)
			else stat.Color:Lerp(UI.Palette.Glass, 0.72)
		pin.BorderSizePixel = 0
		pin.AutoButtonColor = false
		pin.Font = UI.Font.Heading
		pin.TextScaled = true
		pin.TextWrapped = true
		pin.LineHeight = 0.82
		pin.TextColor3 = if recommended or unlocked then MAP_PAPER else UI.Palette.TextMuted
		pin.Text = `{string.sub(string.upper(stat.DisplayName), 1, 2)}\n×{NumberFormat.Format(
			destination.GainMultiplier
		)}`
		pin.ZIndex = if recommended then 27 elseif selected then 25 else 22
		pin.Parent = pins
		addCorner(pin, 20)
		local textLimit = Instance.new("UITextSizeConstraint")
		textLimit.MinTextSize = 6
		textLimit.MaxTextSize = 10
		textLimit.Parent = pin
		local pinStroke = addBorder(
			pin,
			if recommended then UI.Palette.Accent elseif selected then MAP_PAPER else MAP_INK,
			0,
			if recommended then 4 elseif selected then 2 else 1
		)
		pinRecords[destination.Id] = { Button = pin, Stroke = pinStroke, Recommended = recommended }
		UI.Pressable(pin, { PressScale = 0.9, HoverScale = 1.12 })
		pin.Activated:Connect(function()
			selectedDestination = destination.Id
			for id, record in pinRecords do
				local nowSelected = id == selectedDestination
				record.Button.Size = UDim2.fromOffset(
					if record.Recommended
						then RECOMMENDED_PIN_SIZE
						elseif nowSelected then SELECTED_PIN_SIZE
						else PIN_SIZE,
					if record.Recommended
						then RECOMMENDED_PIN_SIZE
						elseif nowSelected then SELECTED_PIN_SIZE
						else PIN_SIZE
				)
				record.Button.ZIndex = if record.Recommended then 27 elseif nowSelected then 25 else 22
				record.Stroke.Color = if record.Recommended
					then UI.Palette.Accent
					elseif nowSelected then MAP_PAPER
					else MAP_INK
				record.Stroke.Thickness = if record.Recommended then 4 elseif nowSelected then 2 else 1
			end
			-- Redraw only the small detail card. Recreating thousands of map-feature
			-- Frames for every pin click made destination selection needlessly heavy.
			for _, child in sidebar:GetChildren() do
				if child:IsA("GuiObject") then
					child:Destroy()
				end
			end
			self:_renderSidebar(sidebar, power)
		end)
	end

	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local here = MapRender.Dot(pins, "You", 12, UI.Palette.Text, 28)
		here.Position = project(root.Position.X, root.Position.Z)
		addBorder(here, MAP_INK, 0, 2)
	end

	local function theoreticalCanvasSize(): Vector2
		return viewport.AbsoluteSize * mapZoom
	end

	local function setCanvasOffset(rawOffset: Vector2)
		local windowSize = viewport.AbsoluteSize
		local canvasSize = theoreticalCanvasSize()
		if windowSize.X <= 0 or windowSize.Y <= 0 then
			return
		end
		local overflow =
			Vector2.new(math.max(canvasSize.X - windowSize.X, 0), math.max(canvasSize.Y - windowSize.Y, 0))
		local offset =
			Vector2.new(math.clamp(rawOffset.X, -overflow.X, 0), math.clamp(rawOffset.Y, -overflow.Y, 0))
		canvas.Position = UDim2.fromOffset(offset.X, offset.Y)
		mapCenter = Vector2.new(
			math.clamp((windowSize.X / 2 - offset.X) / canvasSize.X, 0, 1),
			math.clamp((windowSize.Y / 2 - offset.Y) / canvasSize.Y, 0, 1)
		)
		canvas:SetAttribute("CenterX", mapCenter.X)
		canvas:SetAttribute("CenterY", mapCenter.Y)
	end

	local function applyCenter()
		local windowSize = viewport.AbsoluteSize
		local canvasSize = theoreticalCanvasSize()
		setCanvasOffset(
			Vector2.new(
				windowSize.X / 2 - mapCenter.X * canvasSize.X,
				windowSize.Y / 2 - mapCenter.Y * canvasSize.Y
			)
		)
	end

	local function zoomAt(targetZoom: number, localFocus: Vector2?)
		targetZoom = math.clamp(targetZoom, MIN_ZOOM, MAX_ZOOM)
		if math.abs(targetZoom - mapZoom) < 0.001 then
			return
		end
		local windowSize = viewport.AbsoluteSize
		local oldSize = theoreticalCanvasSize()
		local oldOffset = Vector2.new(canvas.Position.X.Offset, canvas.Position.Y.Offset)
		local focus = localFocus or windowSize / 2
		local normalizedFocus = Vector2.new(
			math.clamp((focus.X - oldOffset.X) / oldSize.X, 0, 1),
			math.clamp((focus.Y - oldOffset.Y) / oldSize.Y, 0, 1)
		)

		mapZoom = targetZoom
		canvas.Size = UDim2.fromScale(mapZoom, mapZoom)
		canvas:SetAttribute("Zoom", mapZoom)
		local newSize = windowSize * mapZoom
		setCanvasOffset(focus - Vector2.new(normalizedFocus.X * newSize.X, normalizedFocus.Y * newSize.Y))
	end

	-- Explicit drag ownership replaces native ScrollingFrame behaviour. No wheel event
	-- can leak into a parent page because there is no parent page to scroll.
	local draggingMouse = false
	local draggingTouch: InputObject? = nil
	local dragStart = Vector2.zero
	local offsetStart = Vector2.zero
	viewport.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		draggingMouse = input.UserInputType == Enum.UserInputType.MouseButton1
		draggingTouch = if input.UserInputType == Enum.UserInputType.Touch then input else nil
		dragStart = Vector2.new(input.Position.X, input.Position.Y)
		offsetStart = Vector2.new(canvas.Position.X.Offset, canvas.Position.Y.Offset)
	end)

	local moveConnection = UserInputService.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseWheel and input.Position.Z ~= 0 then
			local mouse = UserInputService:GetMouseLocation()
			local topLeft = viewport.AbsolutePosition
			local size = viewport.AbsoluteSize
			if
				mouse.X >= topLeft.X
				and mouse.Y >= topLeft.Y
				and mouse.X <= topLeft.X + size.X
				and mouse.Y <= topLeft.Y + size.Y
			then
				local focus = mouse - topLeft
				-- Roblox reports wheel-up as positive Z. Up zooms in; down zooms out.
				zoomAt(mapZoom * (if input.Position.Z > 0 then ZOOM_STEP else 1 / ZOOM_STEP), focus)
			end
			return
		end

		local movingMouse = draggingMouse and input.UserInputType == Enum.UserInputType.MouseMovement
		local movingTouch = draggingTouch ~= nil and input == draggingTouch
		if not movingMouse and not movingTouch then
			return
		end
		local current = Vector2.new(input.Position.X, input.Position.Y)
		setCanvasOffset(offsetStart + (current - dragStart))
	end)

	local endConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			draggingMouse = false
		elseif draggingTouch ~= nil and input == draggingTouch then
			draggingTouch = nil
		end
	end)
	viewport.Destroying:Connect(function()
		moveConnection:Disconnect()
		endConnection:Disconnect()
	end)

	local function mapControl(name: string, caption: string, right: number, onClick: () -> ())
		local control = Instance.new("TextButton")
		control.Name = name
		control.AnchorPoint = Vector2.new(1, 0)
		control.Position = UDim2.new(1, -right, 0, 10)
		control.Size = UDim2.fromOffset(38, 38)
		control.BackgroundColor3 = UI.Palette.Glass
		control.BackgroundTransparency = 0.03
		control.BorderSizePixel = 0
		control.AutoButtonColor = false
		control.Font = UI.Font.Heading
		control.TextSize = 20
		control.TextColor3 = UI.Palette.Text
		control.Text = caption
		control.ZIndex = 60
		control.Parent = board
		addCorner(control, 7)
		addBorder(control, UI.Palette.GlassStroke, 0.35, 2)
		UI.Pressable(control)
		control.Activated:Connect(onClick)
	end

	mapControl("ZoomIn", "+", 10, function()
		zoomAt(mapZoom * ZOOM_STEP)
	end)
	mapControl("ZoomOut", "−", 54, function()
		zoomAt(mapZoom / ZOOM_STEP)
	end)
	mapControl("Reset", "⌂", 98, function()
		mapZoom = 1
		mapCenter = Vector2.new(0.5, 0.5)
		canvas.Size = UDim2.fromScale(1, 1)
		canvas:SetAttribute("Zoom", mapZoom)
		applyCenter()
	end)

	local legend = Instance.new("Frame")
	legend.Name = "Legend"
	legend.Position = UDim2.fromOffset(10, 10)
	legend.Size = UDim2.fromOffset(326, 38)
	legend.BackgroundColor3 = UI.Palette.Glass
	legend.BackgroundTransparency = 0.03
	legend.BorderSizePixel = 0
	legend.ZIndex = 60
	legend.Parent = board
	addCorner(legend, 7)
	addBorder(legend, UI.Palette.GlassStroke, 0.5, 1)
	local legendLayout = Instance.new("UIListLayout")
	legendLayout.FillDirection = Enum.FillDirection.Horizontal
	legendLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	legendLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	legendLayout.Padding = UDim.new(0, 4)
	legendLayout.Parent = legend
	for _, definition in StatConfig.List do
		local key = UI.Label(definition.Id, legend)
		key.Size = UDim2.fromOffset(59, 24)
		key.Font = UI.Font.Heading
		key.TextSize = 9
		key.TextColor3 = definition.Color
		key.Text = `● {string.upper(definition.DisplayName)}`
		key.ZIndex = 61
	end

	local status = UI.Label("Status", board)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 10, 1, -10)
	status.Size = UDim2.fromOffset(390, 28)
	status.BackgroundColor3 = UI.Palette.Glass
	status.BackgroundTransparency = 0.03
	status.Font = UI.Font.Heading
	status.TextSize = 10
	status.TextColor3 = UI.Palette.Text
	status.TextXAlignment = Enum.TextXAlignment.Center
	if recommendation ~= nil then
		local recommendedStat = StatConfig.Get(recommendation.StatId)
		local statName = if recommendedStat ~= nil
			then string.upper(recommendedStat.DisplayName)
			else "MUSCLE"
		status.Text =
			`★ TRAIN {statName} AT ×{NumberFormat.Format(recommendation.GainMultiplier)}  ·  {unlockedCount}/{#destinations} OPEN`
	else
		status.Text = `{unlockedCount}/{#destinations} OPEN  ·  DRAG TO PAN  ·  WHEEL OR +/− TO ZOOM`
	end
	status.ZIndex = 60
	addCorner(status, 7)
	addBorder(status, UI.Palette.GlassStroke, 0.5, 1)

	task.defer(function()
		if viewport.Parent ~= nil then
			applyCenter()
		end
	end)
end

function FullMapController:_build()
	local playerGui = player:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymFullMap"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 6
	screen.Enabled = false
	screen.Parent = playerGui
	UI.ScaleWithViewport(screen)

	-- The scrim is deliberately visual-only. A full-screen TextButton used to treat
	-- the mouse-up at the end of some map drags as an activation and close the page.
	-- Closing is now explicit: the X button, Escape, or M.
	local scrim = Instance.new("Frame")
	scrim.Name = "Scrim"
	scrim.Size = UDim2.fromScale(1, 1)
	scrim.BackgroundColor3 = Color3.new(0, 0, 0)
	scrim.BackgroundTransparency = 0.42
	scrim.BorderSizePixel = 0
	scrim.Active = true
	scrim.Parent = screen

	local panel = UI.Panel("FullMap", screen)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y)
	panel.BackgroundTransparency = 0.01
	-- Sink clicks inside the panel so they cannot reach the 3D world behind the map.
	panel.Active = true
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = PANEL_SIZE.X / PANEL_SIZE.Y
	aspect.Parent = panel

	local title = UI.Label("Title", panel)
	title.Position = UDim2.fromOffset(4, 0)
	title.Size = UDim2.new(1, -180, 0, HEADER_HEIGHT)
	title.Font = UI.Font.Heading
	title.TextSize = 20
	title.TextColor3 = UI.Palette.Text
	title.Text = "CITY TRAINING MAP"

	local subtitle = UI.Label("Subtitle", panel)
	subtitle.AnchorPoint = Vector2.new(1, 0)
	subtitle.Position = UDim2.new(1, -48, 0, 0)
	subtitle.Size = UDim2.fromOffset(310, HEADER_HEIGHT)
	subtitle.Font = UI.Font.Heading
	subtitle.TextSize = 10
	subtitle.TextXAlignment = Enum.TextXAlignment.Right
	subtitle.TextColor3 = UI.Palette.TextMuted
	subtitle.Text = "SELECT A CIRCLE · TRACK FREE · TELEPORT WITH PASS"

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, 0, 0, HEADER_HEIGHT / 2)
	close.Size = UDim2.fromOffset(38, 38)
	close.BackgroundColor3 = UI.Palette.Backdrop
	close.BackgroundTransparency = 0.2
	close.BorderSizePixel = 0
	close.AutoButtonColor = false
	close.Font = UI.Font.Heading
	close.TextSize = 18
	close.TextColor3 = UI.Palette.TextMuted
	close.Text = "✕"
	close.Parent = panel
	addCorner(close, 8)
	UI.Pressable(close)
	close.Activated:Connect(function()
		self:Close()
	end)

	content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(0, HEADER_HEIGHT)
	content.Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT)
	content.BackgroundTransparency = 1
	content.Parent = panel
end

function FullMapController:IsOpen(): boolean
	return isOpen
end

function FullMapController:Open(destinationId: string?)
	local MenuController = Loader.Get("MenuController")
	if MenuController:GetOpenTab() ~= nil then
		MenuController:Toggle()
	end

	self:_fetchMap()
	selectedDestination = if destinationId ~= nil and MapRender.GetDestination(destinationId) ~= nil
		then destinationId
		else nil
	isOpen = true
	screen.Enabled = true
	self:_fetchTravelAccess()
	self:_render()
	FullMapController.Changed:Fire(true)
end

-- Opens the best currently unlocked destination for one muscle. Kept as a small
-- routing API so any future stat-card shortcut still lands on this dedicated surface.
function FullMapController:OpenForStat(statId: string)
	self:_fetchMap()
	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
	local chosen: Destination? = nil
	for _, destination in destinations do
		if destination.StatId == statId and (chosen == nil or power >= destination.RequiredPower) then
			chosen = destination
		end
	end
	self:Open(if chosen ~= nil then chosen.Id else nil)
end

function FullMapController:Close()
	if not isOpen then
		return
	end
	isOpen = false
	screen.Enabled = false
	FullMapController.Changed:Fire(false)
end

function FullMapController:Toggle()
	if isOpen then
		self:Close()
	else
		self:Open()
	end
end

function FullMapController:Start()
	self:_build()

	ProfileController.Changed:Connect(function()
		if not isOpen then
			return
		end
		local data = ProfileController:Get()
		local stats = if data ~= nil then data.Stats else {}
		local power = Formulas.TotalPower(stats)
		local nextRecommendation = self:_recommend(power, stats)
		if (if nextRecommendation ~= nil then nextRecommendation.Id else nil) ~= recommendedDestination then
			if selectedDestination == recommendedDestination then
				selectedDestination = if nextRecommendation ~= nil then nextRecommendation.Id else nil
			end
			self:_render()
			return
		end
		for _, destination in destinations do
			if (renderedPower >= destination.RequiredPower) ~= (power >= destination.RequiredPower) then
				self:_render()
				return
			end
		end
	end)

	-- A successful purchase should unlock the button before the player closes the map.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(
		function(purchasingPlayer: Player, _gamePassId: number, wasPurchased: boolean)
			if purchasingPlayer ~= player or not wasPurchased or not isOpen then
				return
			end
			task.delay(0.25, function()
				if isOpen then
					self:_fetchTravelAccess()
					self:_render()
				end
			end)
		end
	)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not isOpen then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.M then
			self:Close()
		end
	end)
end

return FullMapController
