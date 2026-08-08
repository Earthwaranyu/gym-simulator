--!strict
--[[
	MenuController — the tabbed menu: map, upgrades, quests, shop, leaderboard, settings.

	Tabs are declared in one table with a render function each, so adding a screen is
	an entry rather than a new controller and a new toggle.

	Every list is rebuilt from config and from the replicated profile when its tab is
	opened, so a new stat, quest, or shop item appears with no edit here. Purchases go
	through remotes and the server's reply is shown verbatim — the client never decides
	whether something was affordable.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local MenuController = {
	Name = "MenuController",
	Priority = 7,
}

-- Fires with the id of the screen now showing, or nil when the menu is closed.
-- The button bar highlights whichever tab this names; without it the highlight
-- would have to be set at click time and would then stay lit after Escape or the
-- close button, which do not go through the bar at all.
MenuController.Changed = Signal.new()

local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local body: Frame
local titleLabel: TextLabel
local tabStrip: Frame
local isOpen = false
local activeTab = "Map"
local quests: { any } = {}

type Destination = {
	Id: string,
	ZoneId: string,
	EquipmentId: string,
	StatId: string,
	RequiredPower: number,
	GainMultiplier: number,
	Position: Vector3,
	AccessKind: string,
	FloorIndex: number,
	EnvironmentId: string,
	VariantId: string,
	ExerciseFamily: string,
	RequiresFlight: boolean,
	LocationName: string,
	LocationTagline: string,
}

type MapFeature = {
	Kind: string,
	Shape: string,
	X: number,
	Z: number,
	Width: number,
	Depth: number,
	Rotation: number,
	Color: Color3,
}

-- All training locations come from the server because StreamingEnabled means
-- most physical stations do not exist in the spawn client's Workspace yet.
local destinations: { Destination } = {}
local destinationsById: { [string]: Destination } = {}
local mapFeatures: { MapFeature } = {}
local mapLoaded = false
local selectedDestination: string? = nil

-- Train panel: which muscle group is being shown, and the last live status the server
-- sent. Status is a snapshot rather than a subscription — the panel polls while it is
-- open and stops the moment it is not, so a menu nobody is looking at costs nothing.
local selectedMuscle: string? = nil
local spotStatus: { [string]: any } = {}
local currentSpotId: string? = nil
-- Incremented on every poll start so an in-flight refresh from a closed panel, or from
-- a muscle the player has since switched away from, discards itself instead of
-- redrawing the screen out from under them.
local trainPollToken = 0

-- Whether this player may teleport at all. Refreshed whenever the menu opens, because
-- buying the pass mid-session must change the buttons without a rejoin. The server
-- re-checks on every actual Travel call; this only decides what the button says.
local hasFastTravel = false
local mapZoom = 1
local mapCenter = Vector2.new(0.5, 0.5)

-- The map is the one panel that is NOT dark.
--
-- The rest of the UI is a dark HUD over a bright world, which is right for something
-- you read at a glance. A map is the opposite job: you study it, and every feature on
-- it is a shade of the city's own concrete and asphalt — dark grey shapes on a dark
-- grey board, which is unreadable no matter how carefully the greys are chosen.
-- Lifting the whole thing to paper gives every feature somewhere to contrast against.
local MAP_PAPER = Color3.fromRGB(232, 234, 238)
local MAP_INK = Color3.fromRGB(38, 42, 52)
-- How far each feature's real colour is pulled toward white. High, because the source
-- colours are city-dark; the tint that survives is enough to tell water from park.
local MAP_WASH = 0.62

local MAP_HEIGHT = 300
local MAP_ASPECT = 2.05
local MAP_MIN_ZOOM = 1
local MAP_MAX_ZOOM = 4
local MAP_ZOOM_STEP = 1.25

type Tab = {
	Id: string,
	DisplayName: string,
	Render: (parent: Frame) -> (),
	-- Whether MenuBarController gives this tab an on-screen button. Defaults to
	-- true, so a new screen is reachable without touching the bar; Quests opts
	-- out because Coach in the plaza is how you are meant to find it.
	OnBar: boolean?,
	-- Which glyph in Icons.luau the button draws. Defaults to the tab's own id,
	-- so a tab only names this when the two differ — as Ranks does, whose icon
	-- and label are both "Top".
	Icon: string?,
}

local tabs: { Tab } = {}

--[[
	Lightens a world colour into something readable on paper, keeping its hue so the
	map still reads as the city rather than as an abstract diagram.
]]
local function wash(color: Color3, amount: number?): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount or MAP_WASH)
end

local function row(parent: Frame, height: number, order: number): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = UI.Palette.Backdrop
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(1, 0, 0, height)
	frame.LayoutOrder = order
	frame.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame

	return frame
end

local function button(parent: Frame, text: string, color: Color3, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.AnchorPoint = Vector2.new(1, 0.5)
	btn.Position = UDim2.fromScale(1, 0.5)
	btn.Size = UDim2.fromOffset(104, 28)
	btn.Font = UI.Font.Heading
	btn.TextSize = 14
	btn.TextColor3 = UI.Palette.Backdrop
	btn.Text = text
	btn.AutoButtonColor = true
	btn.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	btn.Activated:Connect(onClick)
	return btn
end

local function toast(message: string)
	if ToastController ~= nil and type(message) == "string" then
		ToastController:Show(message)
	end
end

function MenuController:Init()
	ProfileController = Loader.Get("ProfileController")
	ToastController = Loader.Get("ToastController")

	tabs = {
		{
			Id = "Map",
			DisplayName = "Map",
			Render = function(parent)
				self:_renderMap(parent)
			end,
		},
		{
			Id = "Train",
			DisplayName = "Train",
			Render = function(parent)
				self:_renderTrain(parent)
			end,
		},
		{
			Id = "Upgrades",
			DisplayName = "Upgrades",
			Render = function(parent)
				self:_renderUpgrades(parent)
			end,
		},
		{
			Id = "Quests",
			DisplayName = "Quests",
			OnBar = false,
			Render = function(parent)
				self:_renderQuests(parent)
			end,
		},
		{
			Id = "Shop",
			DisplayName = "Shop",
			Render = function(parent)
				self:_renderShop(parent)
			end,
		},
		{
			Id = "Ranks",
			DisplayName = "Top",
			Icon = "Top",
			Render = function(parent)
				self:_renderLeaderboard(parent)
			end,
		},
		{
			Id = "Settings",
			DisplayName = "Settings",
			Render = function(parent)
				self:_renderSettings(parent)
			end,
		},
	}
end

-- Pull every map-enabled training station from the server once.
function MenuController:_fetchDestinations()
	if mapLoaded then
		return
	end

	local ok, list, features = pcall(function()
		return Net.Function("GetDestinations"):InvokeServer()
	end)
	if not ok or type(list) ~= "table" then
		return
	end

	table.clear(destinations)
	table.clear(destinationsById)
	table.clear(mapFeatures)

	for _, entry in list do
		if
			type(entry) ~= "table"
			or type(entry.Id) ~= "string"
			or type(entry.ZoneId) ~= "string"
			or type(entry.EquipmentId) ~= "string"
			or type(entry.StatId) ~= "string"
			or type(entry.RequiredPower) ~= "number"
			or type(entry.GainMultiplier) ~= "number"
			or type(entry.X) ~= "number"
			or type(entry.Y) ~= "number"
			or type(entry.Z) ~= "number"
		then
			continue
		end
		local destination: Destination = {
			Id = entry.Id,
			ZoneId = entry.ZoneId,
			EquipmentId = entry.EquipmentId,
			StatId = entry.StatId,
			RequiredPower = entry.RequiredPower,
			GainMultiplier = entry.GainMultiplier,
			Position = Vector3.new(entry.X, entry.Y, entry.Z),
			AccessKind = if type(entry.AccessKind) == "string" then entry.AccessKind else "Street",
			FloorIndex = if type(entry.FloorIndex) == "number" then entry.FloorIndex else 1,
			EnvironmentId = if type(entry.EnvironmentId) == "string" then entry.EnvironmentId else "Unknown",
			VariantId = if type(entry.VariantId) == "string" then entry.VariantId else entry.EquipmentId,
			ExerciseFamily = if type(entry.ExerciseFamily) == "string"
				then entry.ExerciseFamily
				else entry.StatId,
			RequiresFlight = entry.RequiresFlight == true,
			LocationName = if type(entry.LocationName) == "string" then entry.LocationName else entry.ZoneId,
			LocationTagline = if type(entry.LocationTagline) == "string" then entry.LocationTagline else "",
		}
		table.insert(destinations, destination)
		destinationsById[destination.Id] = destination
	end

	if type(features) == "table" then
		for _, entry in features do
			if
				type(entry) ~= "table"
				or type(entry.Kind) ~= "string"
				or type(entry.Shape) ~= "string"
				or type(entry.X) ~= "number"
				or type(entry.Z) ~= "number"
				or type(entry.Width) ~= "number"
				or type(entry.Depth) ~= "number"
				or type(entry.Rotation) ~= "number"
				or typeof(entry.Color) ~= "Color3"
			then
				continue
			end
			table.insert(mapFeatures, {
				Kind = entry.Kind,
				Shape = entry.Shape,
				X = entry.X,
				Z = entry.Z,
				Width = entry.Width,
				Depth = entry.Depth,
				Rotation = entry.Rotation,
				Color = entry.Color,
			})
		end
	end

	mapLoaded = #destinations > 0
end

-- Every training location appears immediately. Pin colour is the stat; locked
-- pins stay visible but dim so the map shows both where to go and what to grind for.
function MenuController:_renderMap(parent: Frame)
	self:_fetchDestinations()

	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0

	if selectedDestination == nil then
		for _, destination in destinations do
			if power >= destination.RequiredPower then
				selectedDestination = destination.Id
			end
		end
	end

	local board = Instance.new("Frame")
	board.Name = "Board"
	board.BackgroundColor3 = MAP_PAPER
	board.BackgroundTransparency = 0
	board.BorderSizePixel = 0
	board.Size = UDim2.new(1, 0, 0, MAP_HEIGHT)
	board.LayoutOrder = 1
	board:SetAttribute("DestinationCount", #destinations)
	board:SetAttribute("FeatureCount", #mapFeatures)
	board.Parent = parent

	local boardCorner = Instance.new("UICorner")
	boardCorner.CornerRadius = UDim.new(0, 8)
	boardCorner.Parent = board

	local boardStroke = Instance.new("UIStroke")
	boardStroke.Color = UI.Palette.GlassStroke
	boardStroke.Transparency = 0.75
	boardStroke.Parent = board

	if #destinations == 0 then
		local empty = UI.Label("Empty", board)
		empty.Size = UDim2.fromScale(1, 1)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "The map is still loading."
		return
	end

	-- Bounds come from the real generated land footprint, not from the outermost
	-- pins. That keeps roads, blocks and buildings in their true proportions.
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge
	local function includeFeature(feature: MapFeature)
		local angle = math.rad(feature.Rotation)
		local halfX = math.abs(math.cos(angle)) * feature.Width / 2
			+ math.abs(math.sin(angle)) * feature.Depth / 2
		local halfZ = math.abs(math.sin(angle)) * feature.Width / 2
			+ math.abs(math.cos(angle)) * feature.Depth / 2
		minX, maxX = math.min(minX, feature.X - halfX), math.max(maxX, feature.X + halfX)
		minZ, maxZ = math.min(minZ, feature.Z - halfZ), math.max(maxZ, feature.Z + halfZ)
	end

	local foundLand = false
	for _, feature in mapFeatures do
		if feature.Kind == "Land" then
			includeFeature(feature)
			foundLand = true
		end
	end
	if not foundLand then
		for _, feature in mapFeatures do
			includeFeature(feature)
		end
	end
	-- Aerial locations normally sit over a district, but destinations still take
	-- part in the bounds so a later offshore roof can never produce a clipped pin.
	for _, destination in destinations do
		local at = destination.Position
		minX, maxX = math.min(minX, at.X - 12), math.max(maxX, at.X + 12)
		minZ, maxZ = math.min(minZ, at.Z - 12), math.max(maxZ, at.Z + 12)
	end

	local worldWidth = math.max(maxX - minX, 1)
	local worldDepth = math.max(maxZ - minZ, 1)
	local pad = math.max(worldWidth, worldDepth) * 0.025
	minX, maxX = minX - pad, maxX + pad
	minZ, maxZ = minZ - pad, maxZ + pad
	worldWidth, worldDepth = maxX - minX, maxZ - minZ
	if worldWidth / worldDepth > MAP_ASPECT then
		local targetDepth = worldWidth / MAP_ASPECT
		local extra = (targetDepth - worldDepth) / 2
		minZ, maxZ = minZ - extra, maxZ + extra
	else
		local targetWidth = worldDepth * MAP_ASPECT
		local extra = (targetWidth - worldWidth) / 2
		minX, maxX = minX - extra, maxX + extra
	end
	worldWidth, worldDepth = maxX - minX, maxZ - minZ

	local function project(x: number, z: number): UDim2
		-- World +Z is north, and screen Y grows downward, so Z is flipped.
		return UDim2.fromScale((x - minX) / worldWidth, 1 - (z - minZ) / worldDepth)
	end

	local viewport = Instance.new("ScrollingFrame")
	viewport.Name = "MapViewport"
	viewport.Active = true
	viewport.BackgroundColor3 = Color3.fromRGB(20, 24, 25)
	viewport.BorderSizePixel = 0
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.CanvasSize = UDim2.fromScale(mapZoom, mapZoom)
	viewport.AutomaticCanvasSize = Enum.AutomaticSize.None
	viewport.ScrollingDirection = Enum.ScrollingDirection.XY
	viewport.ElasticBehavior = Enum.ElasticBehavior.Never
	viewport.ScrollBarThickness = 4
	viewport.ScrollBarImageColor3 = UI.Palette.TextMuted
	viewport.ScrollBarImageTransparency = 0.35
	viewport.ClipsDescendants = true
	viewport.Parent = board

	local canvas = Instance.new("Frame")
	canvas.Name = "MapCanvas"
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.Size = UDim2.fromScale(1, 1)
	canvas:SetAttribute("Zoom", mapZoom)
	canvas:SetAttribute("CenterX", mapCenter.X)
	canvas:SetAttribute("CenterY", mapCenter.Y)
	canvas.Parent = viewport

	local featureLayer = Instance.new("Frame")
	featureLayer.Name = "MapFeatures"
	featureLayer.BackgroundTransparency = 1
	featureLayer.Size = UDim2.fromScale(1, 1)
	featureLayer.ZIndex = 1
	featureLayer.Parent = canvas

	local pinLayer = Instance.new("Frame")
	pinLayer.Name = "MapPins"
	pinLayer.BackgroundTransparency = 1
	pinLayer.Size = UDim2.fromScale(1, 1)
	pinLayer.ZIndex = 20
	pinLayer.Parent = canvas

	local featureLayers: { [string]: number } = {
		Water = 1,
		Land = 2,
		Block = 3,
		Park = 4,
		Road = 5,
		Building = 6,
		SkyPlatform = 7,
		Plaza = 8,
		SafeZone = 9,
	}
	for index, feature in mapFeatures do
		local shape = Instance.new("Frame")
		shape.Name = `Feature_{index}_{feature.Kind}`
		shape.AnchorPoint = Vector2.new(0.5, 0.5)
		shape.Position = project(feature.X, feature.Z)
		shape.Size = UDim2.fromScale(feature.Width / worldWidth, feature.Depth / worldDepth)
		shape.Rotation = feature.Rotation
		-- Buildings stay closest to their real colour so streets read as gaps between
		-- them; everything else is washed further out so the pins sit on top of it.
		shape.BackgroundColor3 = wash(feature.Color, if feature.Kind == "Building" then 0.45 else MAP_WASH)
		shape.BackgroundTransparency = if feature.Kind == "SafeZone"
			then 0.45
			elseif feature.Kind == "Water" then 0.1
			elseif feature.Kind == "SkyPlatform" then 0.15
			else 0
		shape.BorderSizePixel = 0
		shape.ZIndex = featureLayers[feature.Kind] or 3
		shape.Parent = featureLayer

		if feature.Shape == "Circle" then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = shape
		elseif feature.Kind == "Building" or feature.Kind == "SafeZone" then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 2)
			corner.Parent = shape
		end
		if feature.Kind == "SafeZone" then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(0, 132, 178)
			stroke.Thickness = 2
			stroke.Parent = shape
		elseif feature.Kind == "SkyPlatform" then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(96, 132, 168)
			stroke.Thickness = 1.5
			stroke.Parent = shape
		end
	end

	local hub = UI.Label("Hub", pinLayer)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(74, 16)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.TextSize = 11
	hub.TextColor3 = Color3.fromRGB(0, 118, 160)
	hub.Text = "SPAWN"
	hub.ZIndex = 24

	local unlockedCount = 0
	for _, destination in destinations do
		local stat = StatConfig.Get(destination.StatId)
		if stat == nil then
			continue
		end

		local unlocked = power >= destination.RequiredPower
		if unlocked then
			unlockedCount += 1
		end
		local isSelected = selectedDestination == destination.Id
		local size = if isSelected then 34 else 27
		local at = destination.Position

		local pin = Instance.new("TextButton")
		pin.Name = destination.Id
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = project(at.X, at.Z)
		pin.Size = UDim2.fromOffset(size, size)
		-- On paper a transparent pin disappears into the board, so a locked pin is
		-- washed out rather than faded — still visibly a pin, still visibly its muscle
		-- group, obviously not available.
		pin.BackgroundColor3 = if unlocked then stat.Color else wash(stat.Color, 0.55)
		pin.BackgroundTransparency = 0
		pin.BorderSizePixel = 0
		pin.Font = UI.Font.Numeric
		pin.TextSize = 9
		pin.TextColor3 = if unlocked then MAP_PAPER else MAP_INK
		pin.TextWrapped = true
		pin.Text = `{string.sub(stat.DisplayName, 1, 1)}\n×{NumberFormat.Format(destination.GainMultiplier)}`
		pin.ZIndex = if isSelected then 24 else 22
		pin:SetAttribute("EnvironmentId", destination.EnvironmentId)
		pin:SetAttribute("ExerciseFamily", destination.ExerciseFamily)
		pin:SetAttribute("VariantId", destination.VariantId)
		pin:SetAttribute("AccessKind", destination.AccessKind)
		pin:SetAttribute("RequiresFlight", destination.RequiresFlight)
		pin:SetAttribute("LocationName", destination.LocationName)
		pin:SetAttribute("GainMultiplier", destination.GainMultiplier)
		pin.Parent = pinLayer

		local pinCorner = Instance.new("UICorner")
		pinCorner.CornerRadius = UDim.new(1, 0)
		pinCorner.Parent = pin

		local pinStroke = Instance.new("UIStroke")
		pinStroke.Color = if isSelected then MAP_INK else wash(MAP_INK, 0.45)
		pinStroke.Thickness = if isSelected then 2 else 1
		pinStroke.Parent = pin

		pin.Activated:Connect(function()
			local canvasSize = viewport.AbsoluteCanvasSize
			local windowSize = viewport.AbsoluteWindowSize
			if canvasSize.X > 0 and canvasSize.Y > 0 then
				mapCenter = Vector2.new(
					math.clamp((viewport.CanvasPosition.X + windowSize.X / 2) / canvasSize.X, 0, 1),
					math.clamp((viewport.CanvasPosition.Y + windowSize.Y / 2) / canvasSize.Y, 0, 1)
				)
			end
			selectedDestination = destination.Id
			self:_refresh()
		end)
	end

	-- Where the player is standing, so the map answers "where am I" as well as
	-- "where can I go".
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root ~= nil and root:IsA("BasePart") then
		local here = Instance.new("Frame")
		here.Name = "You"
		here.AnchorPoint = Vector2.new(0.5, 0.5)
		here.Position = project(root.Position.X, root.Position.Z)
		here.Size = UDim2.fromOffset(10, 10)
		here.BackgroundColor3 = UI.Palette.Text
		here.BorderSizePixel = 0
		here.ZIndex = 25
		here.Parent = pinLayer

		local hereCorner = Instance.new("UICorner")
		hereCorner.CornerRadius = UDim.new(1, 0)
		hereCorner.Parent = here
	end

	local settingCanvasPosition = false
	local function rememberCenter()
		if settingCanvasPosition then
			return
		end
		local canvasSize = viewport.AbsoluteCanvasSize
		local windowSize = viewport.AbsoluteWindowSize
		if canvasSize.X <= 0 or canvasSize.Y <= 0 then
			return
		end
		mapCenter = Vector2.new(
			math.clamp((viewport.CanvasPosition.X + windowSize.X / 2) / canvasSize.X, 0, 1),
			math.clamp((viewport.CanvasPosition.Y + windowSize.Y / 2) / canvasSize.Y, 0, 1)
		)
		canvas:SetAttribute("CenterX", mapCenter.X)
		canvas:SetAttribute("CenterY", mapCenter.Y)
	end

	local function setCanvasPosition(position: Vector2)
		local canvasSize = viewport.AbsoluteCanvasSize
		local windowSize = viewport.AbsoluteWindowSize
		local maxPosition =
			Vector2.new(math.max(canvasSize.X - windowSize.X, 0), math.max(canvasSize.Y - windowSize.Y, 0))
		settingCanvasPosition = true
		viewport.CanvasPosition =
			Vector2.new(math.clamp(position.X, 0, maxPosition.X), math.clamp(position.Y, 0, maxPosition.Y))
		settingCanvasPosition = false
		rememberCenter()
	end

	local function zoomAt(targetZoom: number, focus: Vector2?)
		targetZoom = math.clamp(targetZoom, MAP_MIN_ZOOM, MAP_MAX_ZOOM)
		if math.abs(targetZoom - mapZoom) < 0.001 then
			return
		end
		local oldSize = viewport.AbsoluteCanvasSize
		local windowSize = viewport.AbsoluteWindowSize
		local localFocus = focus or windowSize / 2
		local focusPoint = mapCenter
		if oldSize.X > 0 and oldSize.Y > 0 then
			focusPoint = Vector2.new(
				(viewport.CanvasPosition.X + localFocus.X) / oldSize.X,
				(viewport.CanvasPosition.Y + localFocus.Y) / oldSize.Y
			)
		end

		mapZoom = targetZoom
		viewport.CanvasSize = UDim2.fromScale(mapZoom, mapZoom)
		canvas:SetAttribute("Zoom", mapZoom)
		task.defer(function()
			if viewport.Parent == nil then
				return
			end
			local newSize = viewport.AbsoluteCanvasSize
			setCanvasPosition(
				Vector2.new(focusPoint.X * newSize.X - localFocus.X, focusPoint.Y * newSize.Y - localFocus.Y)
			)
		end)
	end

	viewport:GetPropertyChangedSignal("CanvasPosition"):Connect(rememberCenter)
	viewport.InputChanged:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseWheel or input.Position.Z == 0 then
			return
		end
		local mouse = UserInputService:GetMouseLocation()
		local focus = Vector2.new(
			math.clamp(mouse.X - viewport.AbsolutePosition.X, 0, viewport.AbsoluteWindowSize.X),
			math.clamp(mouse.Y - viewport.AbsolutePosition.Y, 0, viewport.AbsoluteWindowSize.Y)
		)
		zoomAt(mapZoom * (if input.Position.Z > 0 then MAP_ZOOM_STEP else 1 / MAP_ZOOM_STEP), focus)
	end)

	-- Touch devices get native ScrollingFrame panning; desktop gets the same
	-- grab-and-drag interaction instead of being limited to tiny scrollbars.
	local dragging = false
	local dragStart = Vector2.zero
	local scrollStart = Vector2.zero
	viewport.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		dragging = true
		dragStart = Vector2.new(input.Position.X, input.Position.Y)
		scrollStart = viewport.CanvasPosition
	end)
	local moveConnection = UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local current = Vector2.new(input.Position.X, input.Position.Y)
		setCanvasPosition(scrollStart - (current - dragStart))
	end)
	local endConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
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
		control.BackgroundTransparency = 0.05
		control.BorderSizePixel = 0
		control.Font = UI.Font.Heading
		control.TextSize = 21
		control.TextColor3 = UI.Palette.Text
		control.Text = caption
		control.ZIndex = 50
		control.Parent = board
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = control
		local stroke = Instance.new("UIStroke")
		stroke.Color = UI.Palette.GlassStroke
		stroke.Transparency = 0.55
		stroke.Parent = control
		control.Activated:Connect(onClick)
	end

	mapControl("ZoomIn", "+", 10, function()
		zoomAt(mapZoom * MAP_ZOOM_STEP)
	end)
	mapControl("ZoomOut", "−", 54, function()
		zoomAt(mapZoom / MAP_ZOOM_STEP)
	end)
	mapControl("Recenter", "⌂", 98, function()
		mapZoom = 1
		mapCenter = Vector2.new(0.5, 0.5)
		viewport.CanvasSize = UDim2.fromScale(1, 1)
		canvas:SetAttribute("Zoom", mapZoom)
		task.defer(function()
			if viewport.Parent ~= nil then
				setCanvasPosition(Vector2.zero)
			end
		end)
	end)

	local legend = Instance.new("Frame")
	legend.Name = "Legend"
	legend.Position = UDim2.fromOffset(10, 10)
	legend.Size = UDim2.fromOffset(326, 38)
	legend.BackgroundColor3 = UI.Palette.Glass
	legend.BackgroundTransparency = 0.05
	legend.BorderSizePixel = 0
	legend.ZIndex = 50
	legend.Parent = board
	local legendCorner = Instance.new("UICorner")
	legendCorner.CornerRadius = UDim.new(0, 6)
	legendCorner.Parent = legend
	local legendPadding = Instance.new("UIPadding")
	legendPadding.PaddingLeft = UDim.new(0, 8)
	legendPadding.PaddingRight = UDim.new(0, 8)
	legendPadding.Parent = legend
	local legendLayout = Instance.new("UIListLayout")
	legendLayout.FillDirection = Enum.FillDirection.Horizontal
	legendLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	legendLayout.Padding = UDim.new(0, 5)
	legendLayout.Parent = legend
	for _, definition in StatConfig.List do
		local key = UI.Label(definition.Id, legend)
		key.Size = UDim2.fromOffset(57, 24)
		key.Font = UI.Font.Heading
		key.TextSize = 10
		key.TextColor3 = definition.Color
		key.Text = `● {definition.DisplayName}`
		key.ZIndex = 51
	end

	-- Reapply the persisted view after a pin/profile refresh rebuilt the tab.
	task.defer(function()
		if viewport.Parent == nil then
			return
		end
		local canvasSize = viewport.AbsoluteCanvasSize
		local windowSize = viewport.AbsoluteWindowSize
		setCanvasPosition(
			Vector2.new(
				mapCenter.X * canvasSize.X - windowSize.X / 2,
				mapCenter.Y * canvasSize.Y - windowSize.Y / 2
			)
		)
	end)

	local count = UI.Label("Count", parent)
	count.Size = UDim2.new(1, 0, 0, 20)
	count.LayoutOrder = 2
	count.TextSize = 12
	count.TextColor3 = UI.Palette.TextMuted
	count.Text = `{unlockedCount} of {#destinations} training locations open  ·  all locations shown`

	self:_renderDestination(parent, power)

	-- Point of sale for the pass that lifts the "from the plaza only" rule. The
	-- price is left to Roblox's own prompt rather than repeated here: the product
	-- lives on the server, so any number written in the client is a copy that can
	-- drift. Until the gamepass exists in the dashboard the server answers "not
	-- available yet", which the toast shows verbatim.
	local upsell = row(parent, 44, 6)
	local pitch = UI.Label("Pitch", upsell)
	pitch.Size = UDim2.new(1, -120, 1, 0)
	pitch.TextSize = 13
	pitch.TextColor3 = UI.Palette.TextMuted
	pitch.Text = "<b>Fast Travel</b>  —  go from anywhere, not just the plaza"

	button(upsell, "Get", UI.Palette.Token, function()
		local _, message = Net.Function("PromptProduct"):InvokeServer("FastTravel")
		toast(message)
	end)
end

-- The selected machine, its stat, tier multiplier and travel button.
function MenuController:_renderDestination(parent: Frame, power: number)
	local destination = if selectedDestination ~= nil then destinationsById[selectedDestination] else nil
	if destination == nil then
		return
	end
	local zone = ZoneConfig.Get(destination.ZoneId)
	local equipment = EquipmentConfig.Get(destination.EquipmentId)
	local stat = StatConfig.Get(destination.StatId)
	if zone == nil or equipment == nil or stat == nil then
		return
	end

	local heading = UI.Label("Name", parent)
	heading.Size = UDim2.new(1, 0, 0, 24)
	heading.LayoutOrder = 3
	heading.Font = UI.Font.Heading
	heading.TextSize = 17
	heading.TextColor3 = stat.Color
	heading.Text = string.upper(`{stat.DisplayName} · {equipment.DisplayName}`)

	local tagline = UI.Label("Tagline", parent)
	tagline.Size = UDim2.new(1, 0, 0, 18)
	tagline.LayoutOrder = 4
	tagline.TextSize = 13
	tagline.TextColor3 = UI.Palette.TextMuted
	local access = if destination.AccessKind == "Sky"
		then `sky deck at {math.round(destination.Position.Y)} studs · flight required`
		elseif destination.FloorIndex > 1 then `floor {destination.FloorIndex} interior`
		else "street level"
	tagline.Text = `{destination.LocationName}  ·  {access}  ·  {destination.LocationTagline}`

	local action = row(parent, 44, 5)
	local detail = UI.Label("Detail", action)
	detail.Size = UDim2.new(1, -120, 1, 0)
	detail.TextSize = 13

	local shortfall = destination.RequiredPower - power
	if shortfall > 0 then
		detail.Text = `<font color="#FF5C5C">Needs {NumberFormat.Format(shortfall)} more power</font>`
			.. `  ·  x{NumberFormat.Format(destination.GainMultiplier)} gains`
		local locked = UI.Label("Locked", action)
		locked.AnchorPoint = Vector2.new(1, 0.5)
		locked.Position = UDim2.fromScale(1, 0.5)
		locked.Size = UDim2.fromOffset(104, 28)
		locked.TextXAlignment = Enum.TextXAlignment.Center
		locked.Font = UI.Font.Heading
		locked.TextColor3 = UI.Palette.TextMuted
		locked.Text = "LOCKED"
		return
	end

	detail.Text = `x{NumberFormat.Format(destination.GainMultiplier)} gains  ·  `
		.. `<font color="#7EE7FF">open</font>`

	button(action, if hasFastTravel then "Travel" else "Track", stat.Color, function()
		self:_goTo(destination, `{equipment.DisplayName} · {zone.DisplayName}`, stat.Color)
	end)
end

--[[
	Asks the server for live occupancy and where the player is currently training.

	Wrapped in pcall because a remote can fail while a district streams or a player
	leaves mid-call, and a menu that errors is worse than a menu showing slightly stale
	occupancy.
]]
--[[
	Refreshes whether destination buttons offer "Go" or "Track".
]]
function MenuController:_fetchTravelAccess()
	local ok, access = pcall(function()
		return Net.Function("GetTravelAccess"):InvokeServer()
	end)
	if ok and type(access) == "table" then
		hasFastTravel = access.HasFastTravel == true
	end
end

--[[
	Acts on a chosen destination.

	With the pass, this teleports. Without it, the destination becomes a tracked
	waypoint and the menu closes so the player can start moving — the same button, and
	never a dead end. The refusal string is matched rather than the ownership flag so
	that a player whose pass state changed a second ago still gets the right outcome:
	the server is the only thing that decides.
]]
function MenuController:_goTo(destination: Destination, label: string, color: Color3)
	if hasFastTravel then
		local ok, message = Net.Function("Travel"):InvokeServer(destination.Id)
		if ok then
			toast(message)
			self:Toggle()
			return
		end
		if message ~= "NO_FAST_TRAVEL" then
			toast(message)
			return
		end
		hasFastTravel = false
	end

	local WaypointController = Loader.Get("WaypointController")
	WaypointController:SetTarget(destination.Position, label, color)
	toast(`Tracking {label} — follow the arrow`)
	self:Toggle()
end

function MenuController:_fetchSpotStatus()
	local ok, status = pcall(function()
		return Net.Function("GetSpotStatus"):InvokeServer()
	end)
	if not ok or type(status) ~= "table" or type(status.Spots) ~= "table" then
		return
	end

	spotStatus = status.Spots
	currentSpotId = if type(status.CurrentSpot) == "string" then status.CurrentSpot else nil
end

--[[
	Keeps the Train panel live while it is the tab on screen.

	Polling rather than pushing: occupancy changes constantly across training stations and
	sending every change to every client would cost far more bandwidth than answering
	the handful of players who actually have the panel open. The loop ends as soon as
	the panel is not showing, so it is not a background cost.
]]
function MenuController:_pollTrainPanel()
	trainPollToken += 1
	local token = trainPollToken

	task.spawn(function()
		while token == trainPollToken and isOpen and activeTab == "Train" do
			task.wait(2)
			if token ~= trainPollToken or not isOpen or activeTab ~= "Train" then
				return
			end
			self:_fetchSpotStatus()
			if token == trainPollToken and isOpen and activeTab == "Train" then
				self:_refresh()
			end
		end
	end)
end

--[[
	Train — "where do I train this muscle, right now?"

	The map answers "where is everything"; this answers the question a player actually
	has while standing in a district wondering why their Back is behind. Pick a muscle,
	see every station in the game that trains it, sorted by what it is worth, with the
	ones you can use right now first and a live free/busy count on each.
]]
function MenuController:_renderTrain(parent: Frame)
	self:_fetchDestinations()

	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0

	if selectedMuscle == nil then
		-- Default to the muscle the player is furthest behind on, which is the reason
		-- they opened this panel in nearly every case.
		local lowest: string? = nil
		for _, definition in StatConfig.List do
			local value = if data ~= nil then (data.Stats[definition.Id] or 0) else 0
			local lowestValue = if lowest ~= nil and data ~= nil then (data.Stats[lowest] or 0) else math.huge
			if lowest == nil or value < lowestValue then
				lowest = definition.Id
			end
		end
		selectedMuscle = lowest or StatConfig.List[1].Id
	end

	-- === Muscle chips ====================================================

	local chips = Instance.new("Frame")
	chips.Name = "Muscles"
	chips.BackgroundTransparency = 1
	chips.Size = UDim2.new(1, 0, 0, 38)
	chips.LayoutOrder = 1
	chips.Parent = parent

	local chipLayout = Instance.new("UIListLayout")
	chipLayout.FillDirection = Enum.FillDirection.Horizontal
	chipLayout.SortOrder = Enum.SortOrder.LayoutOrder
	chipLayout.Padding = UDim.new(0, 6)
	chipLayout.Parent = chips

	for index, definition in StatConfig.List do
		local selected = definition.Id == selectedMuscle

		local chip = Instance.new("TextButton")
		chip.Name = definition.Id
		chip.LayoutOrder = index
		chip.Size = UDim2.new(0.2, -5, 1, 0)
		chip.BackgroundColor3 = if selected then definition.Color else UI.Palette.Backdrop
		chip.BackgroundTransparency = if selected then 0 else 0.4
		chip.BorderSizePixel = 0
		chip.AutoButtonColor = false
		chip.Font = UI.Font.Heading
		chip.TextSize = 13
		chip.TextColor3 = if selected then UI.Palette.Backdrop else definition.Color
		chip.Text = string.upper(definition.DisplayName)
		chip.Parent = chips
		UI.Pressable(chip)

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = chip

		chip.Activated:Connect(function()
			selectedMuscle = definition.Id
			self:_refresh()
		end)
	end

	local stat = StatConfig.Get(selectedMuscle :: string)
	if stat == nil then
		return
	end

	-- === The stations for that muscle ====================================

	local spots = {}
	for _, destination in destinations do
		if destination.StatId ~= selectedMuscle then
			continue
		end
		local equipment = EquipmentConfig.Get(destination.EquipmentId)
		if equipment == nil then
			continue
		end
		-- Base rate before the player's own multipliers: what this machine is worth
		-- relative to the others, which is the comparison the panel exists to make.
		local perSecond = (equipment.BaseGain / equipment.RepInterval) * destination.GainMultiplier
		table.insert(spots, {
			Destination = destination,
			Equipment = equipment,
			PerSecond = perSecond,
			Unlocked = power >= destination.RequiredPower,
		})
	end

	-- Usable machines first, best rate first within each group. A locked machine is
	-- still shown — it is the thing being grinded toward — but never above one that
	-- can be walked to right now.
	table.sort(spots, function(a, b)
		if a.Unlocked ~= b.Unlocked then
			return a.Unlocked
		end
		if a.Unlocked then
			-- Weakest first. The list is read as a ladder — where you train now, then
			-- what you are working toward — and sorting the endgame machine to the top
			-- puts the one entry you cannot use for twenty hours where your eye lands.
			return a.PerSecond < b.PerSecond
		end
		return a.Destination.RequiredPower < b.Destination.RequiredPower
	end)

	local summary = UI.Label("Summary", parent)
	summary.Size = UDim2.new(1, 0, 0, 20)
	summary.LayoutOrder = 2
	summary.TextSize = 13
	summary.TextColor3 = UI.Palette.TextMuted
	local open = 0
	for _, spot in spots do
		if spot.Unlocked then
			open += 1
		end
	end
	summary.Text = `{open} of {#spots} {stat.DisplayName} stations open to you  ·  `
		.. (
			if hasFastTravel
				then `<font color="#8A93A8">Go teleports you</font>`
				else `<font color="#8A93A8">Track points you there — Fast Travel teleports</font>`
		)

	if #spots == 0 then
		local empty = UI.Label("Empty", parent)
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.LayoutOrder = 3
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "The map is still loading."
		return
	end

	for index, spot in spots do
		local destination = spot.Destination
		local status = spotStatus[destination.Id]
		local here = currentSpotId == destination.Id

		local line = row(parent, 54, index + 2)

		local title = UI.Label("Title", line)
		title.Size = UDim2.new(1, -110, 0, 24)
		title.Position = UDim2.fromOffset(0, 5)
		title.TextColor3 = if spot.Unlocked then stat.Color else UI.Palette.TextMuted
		local zoneName = destination.LocationName
		title.Text = `×{NumberFormat.Format(destination.GainMultiplier)}  {spot.Equipment.DisplayName}`
			.. `  <font color="#8A93A8">{zoneName}</font>`
			.. (if here then `  <font color="#7EE7FF">· YOU ARE HERE</font>` else "")

		-- Free/busy is the "current" half of the question. Absent status means the
		-- station has not bound on the server yet, which is different from being full.
		local occupancy = if type(status) == "table"
			then `{math.max(0, status.Capacity - status.Occupied)}/{status.Capacity} free`
			else "checking…"

		local detail = UI.Label("Detail", line)
		detail.Size = UDim2.new(1, -110, 0, 18)
		detail.Position = UDim2.fromOffset(0, 29)
		detail.TextSize = 13
		detail.TextColor3 = UI.Palette.TextMuted

		local access = if destination.AccessKind == "Sky"
			then "flight required"
			elseif destination.FloorIndex > 1 then `floor {destination.FloorIndex}`
			else "street level"

		if spot.Unlocked then
			detail.Text = `{NumberFormat.Format(spot.PerSecond)}/s  ·  `
				.. `x{NumberFormat.Format(destination.GainMultiplier)}  ·  {occupancy}  ·  {access}`

			local action = if here then "Here" elseif hasFastTravel then "Go" else "Track"
			button(line, action, stat.Color, function()
				self:_goTo(destination, `{spot.Equipment.DisplayName} · {zoneName}`, stat.Color)
			end)
		else
			local shortfall = destination.RequiredPower - power
			detail.Text = `<font color="#FF5C5C">needs {NumberFormat.Format(shortfall)} more power</font>`
				.. `  ·  {NumberFormat.Format(spot.PerSecond)}/s  ·  {access}`

			local locked = UI.Label("Locked", line)
			locked.AnchorPoint = Vector2.new(1, 0.5)
			locked.Position = UDim2.fromScale(1, 0.5)
			locked.Size = UDim2.fromOffset(96, 28)
			locked.TextXAlignment = Enum.TextXAlignment.Center
			locked.Font = UI.Font.Heading
			locked.TextColor3 = UI.Palette.TextMuted
			locked.Text = "LOCKED"
		end
	end
end

-- Opens the one destination for a muscle from the persistent five-stat hotbar.
-- The same method remains valid if a later season adds more locations: Train still
-- owns the list and selection, while the HUD only names the stat it wants to inspect.
function MenuController:OpenTrain(statId: string)
	if StatConfig.Get(statId) == nil then
		warn(`[MenuController] No stat named "{statId}"`)
		return
	end
	selectedMuscle = statId
	self:Open("Train")
end

function MenuController:_renderUpgrades(parent: Frame)
	local data = ProfileController:Get()

	for index, definition in StatConfig.List do
		local level = if data ~= nil then (data.MultiplierLevels[definition.Id] or 0) else 0
		local cost = Formulas.MultiplierCost(level)

		local line = row(parent, 56, index)

		local label = UI.Label("Text", line)
		label.Size = UDim2.new(1, -120, 0, 26)
		label.Position = UDim2.fromOffset(0, 6)
		label.TextColor3 = definition.Color
		label.Text = `{definition.DisplayName}  <font color="#8A93A8">lvl {level} · </font>`
			.. `x{NumberFormat.Format(Formulas.MultiplierValue(level))}`

		-- What the stat is currently worth, from the stat's own definition. The
		-- number you are about to buy a multiplier on, shown before you buy it.
		local effect = UI.Label("Effect", line)
		effect.Size = UDim2.new(1, -120, 0, 18)
		effect.Position = UDim2.fromOffset(0, 30)
		effect.TextSize = 13
		effect.TextColor3 = UI.Palette.TextMuted
		effect.Text = definition.Effect(if data ~= nil then data.Stats else {})

		button(line, `{NumberFormat.Format(cost)} 🪙`, UI.Palette.Token, function()
			local ok, message = Net.Function("PurchaseMultiplier"):InvokeServer(definition.Id)
			toast(message)
			if ok then
				self:_refresh()
			end
		end)
	end
end

function MenuController:_renderQuests(parent: Frame)
	if #quests == 0 then
		local empty = UI.Label("Empty", parent)
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "No quests available."
		return
	end

	for index, quest in quests do
		local line = row(parent, 48, index)

		local label = UI.Label("Text", line)
		label.Size = UDim2.fromScale(1, 1)

		local status = if quest.Complete
			then `<font color="#66BB6A">complete</font>`
			else `{NumberFormat.Format(quest.Progress)} / {NumberFormat.Format(quest.Goal)}`

		label.Text = `{quest.DisplayName}  <font color="#8A93A8">{quest.Description}</font>\n`
			.. `{status}  <font color="#7EE7FF">+{quest.TokenReward} tokens</font>`
		label.TextSize = 13
	end
end

function MenuController:_renderShop(parent: Frame)
	for index, item in ShopConfig.List do
		local line = row(parent, 46, index)

		local label = UI.Label("Text", line)
		label.Size = UDim2.new(1, -120, 1, 0)
		label.TextSize = 13
		label.Text = `{item.DisplayName}\n<font color="#8A93A8">{item.Description}</font>`

		button(line, `${NumberFormat.Format(item.Price)}`, UI.Palette.Accent, function()
			local ok, message = Net.Function("PurchaseShopItem"):InvokeServer(item.Id)
			toast(message)
			if ok then
				self:_refresh()
			end
		end)
	end
end

function MenuController:_renderLeaderboard(parent: Frame)
	local ok, boards = pcall(function()
		return Net.Function("GetLeaderboard"):InvokeServer()
	end)

	if not ok or type(boards) ~= "table" or #boards == 0 then
		local empty = UI.Label("Empty", parent)
		empty.Size = UDim2.new(1, 0, 0, 40)
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "Leaderboards are still loading."
		return
	end

	local order = 0
	for _, board in boards do
		order += 1
		local heading = UI.Label("Heading", parent)
		heading.Size = UDim2.new(1, 0, 0, 26)
		heading.LayoutOrder = order
		heading.Font = UI.Font.Heading
		heading.TextColor3 = UI.Palette.Accent
		heading.Text = string.upper(board.DisplayName)

		if #board.Entries == 0 then
			order += 1
			local empty = UI.Label("Empty", parent)
			empty.Size = UDim2.new(1, 0, 0, 22)
			empty.LayoutOrder = order
			empty.TextSize = 13
			empty.TextColor3 = UI.Palette.TextMuted
			empty.Text = "  no entries yet"
		end

		for _, entry in board.Entries do
			order += 1
			local label = UI.Label("Entry", parent)
			label.Size = UDim2.new(1, 0, 0, 22)
			label.LayoutOrder = order
			label.TextSize = 13
			label.Text = `  {entry.Rank}. {entry.Name}  `
				.. `<font color="#FFD666">{NumberFormat.Format(entry.Value)}</font>`
		end
	end
end

function MenuController:_renderSettings(parent: Frame)
	local claim = row(parent, 44, 1)

	local label = UI.Label("Text", claim)
	label.Size = UDim2.new(1, -120, 1, 0)
	label.Text = "VIP daily potion"

	button(claim, "Claim", UI.Palette.Token, function()
		local _, message = Net.Function("ClaimVipDaily"):InvokeServer()
		toast(message)
	end)

	local note = UI.Label("Note", parent)
	note.Size = UDim2.new(1, 0, 0, 92)
	note.LayoutOrder = 2
	note.TextSize = 13
	note.TextWrapped = true
	note.TextColor3 = UI.Palette.TextMuted
	note.Text = "Walk up to any machine to train automatically.\n"
		.. "Hold Left Shift to sprint — Legs makes sprinting faster.\n"
		.. "Q flies, Space climbs, Left Control descends.\n"
		.. "Press F to punch whoever you are looking at.\n"
		.. "Tab toggles the player list."
end

function MenuController:_refresh()
	if not isOpen then
		return
	end

	body:ClearAllChildren()
	local layout = UI.VerticalList(body, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder

	for _, tab in tabs do
		if tab.Id == activeTab then
			titleLabel.Text = string.upper(tab.DisplayName)
			tab.Render(body)
			break
		end
	end

	self:_renderTabStrip()
end

function MenuController:_renderTabStrip()
	tabStrip:ClearAllChildren()

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = tabStrip

	for index, tab in tabs do
		local btn = Instance.new("TextButton")
		btn.BackgroundColor3 = if tab.Id == activeTab then UI.Palette.Accent else UI.Palette.Backdrop
		btn.BackgroundTransparency = if tab.Id == activeTab then 0 else 0.4
		btn.BorderSizePixel = 0
		btn.Size = UDim2.fromOffset(96, 30)
		btn.LayoutOrder = index
		btn.Font = UI.Font.Heading
		btn.TextSize = 14
		btn.TextColor3 = if tab.Id == activeTab then UI.Palette.Backdrop else UI.Palette.Text
		btn.Text = tab.DisplayName
		btn.Parent = tabStrip

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = btn

		btn.Activated:Connect(function()
			activeTab = tab.Id
			self:_enterTab()
			self:_refresh()
			self:_publish()
		end)
	end
end

--[[
	Toggles the menu. With a tab id, toggles *that* screen: opens on it, or closes
	if it is already the one showing — which is what a button in a bar has to do,
	because pressing it twice should put you back where you were.
]]
function MenuController:Toggle(tabId: string?)
	if tabId ~= nil and isOpen and activeTab ~= tabId then
		self:Open(tabId)
		return
	end

	isOpen = not isOpen
	screen.Enabled = isOpen

	if isOpen then
		if tabId ~= nil then
			activeTab = tabId
		end
		self:_enterTab()
		self:_refresh()
	else
		-- Closing invalidates any in-flight Train poll, so a panel nobody is looking
		-- at stops asking the server questions.
		trainPollToken += 1
	end

	self:_publish()
end

--[[
	The tabs that should appear as on-screen buttons, in declaration order.
]]
function MenuController:GetBarTabs(): { { Id: string, DisplayName: string, Icon: string } }
	local out = {}
	for _, tab in tabs do
		if tab.OnBar ~= false then
			table.insert(out, {
				Id = tab.Id,
				DisplayName = tab.DisplayName,
				Icon = tab.Icon or tab.Id,
			})
		end
	end
	return out
end

--[[
	Announces what is on screen. Every path that opens or closes the menu ends
	here, so nothing has to remember to tell the bar.
]]
function MenuController:_publish()
	MenuController.Changed:Fire(if isOpen then activeTab else nil)
end

--[[
	The tab currently showing, or nil when the menu is closed.
]]
function MenuController:GetOpenTab(): string?
	return if isOpen then activeTab else nil
end

--[[
	Opens the menu on a named tab, for anything in the world that wants to put a
	screen in front of the player — the quest giver in the plaza, and whatever
	stands next to him later.

	An unknown tab id opens the menu on whatever was last showing rather than
	failing silently on a blank panel, and says so, because a mistyped tab in a
	config table should be visible to whoever wrote it.
]]
function MenuController:Open(tabId: string)
	local known = false
	for _, tab in tabs do
		if tab.Id == tabId then
			known = true
			break
		end
	end

	if known then
		activeTab = tabId
	else
		warn(`[MenuController] No tab named "{tabId}"`)
	end

	isOpen = true
	screen.Enabled = true
	self:_enterTab()
	self:_refresh()
	self:_publish()
end

--[[
	Work a tab needs done before its first frame, rather than after it.

	The Train panel fetches live occupancy here so it opens showing real free/busy
	counts instead of "checking…" for two seconds — the first frame is the one the
	player actually reads.
]]
function MenuController:_enterTab()
	self:_fetchTravelAccess()

	if activeTab == "Train" then
		self:_fetchSpotStatus()
		self:_pollTrainPanel()
	else
		trainPollToken += 1
	end
end

function MenuController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymMenu"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 5
	screen.Enabled = false
	screen.Parent = playerGui

	local panel = UI.Panel("Menu", screen)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(640, 500)
	panel.BackgroundTransparency = 0.05

	titleLabel = UI.Label("Title", panel)
	titleLabel.Size = UDim2.new(1, 0, 0, 28)
	titleLabel.Font = UI.Font.Heading
	titleLabel.TextSize = 20
	titleLabel.TextColor3 = UI.Palette.Accent

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)
	close.Size = UDim2.fromOffset(28, 28)
	close.BackgroundTransparency = 1
	close.Font = UI.Font.Heading
	close.TextSize = 20
	close.TextColor3 = UI.Palette.TextMuted
	close.Text = "✕"
	close.Parent = panel
	close.Activated:Connect(function()
		self:Toggle()
	end)

	tabStrip = Instance.new("Frame")
	tabStrip.Name = "Tabs"
	tabStrip.BackgroundTransparency = 1
	tabStrip.Position = UDim2.fromOffset(0, 34)
	tabStrip.Size = UDim2.new(1, 0, 0, 30)
	tabStrip.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, 72)
	scroll.Size = UDim2.new(1, 0, 1, -72)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.Parent = panel

	body = scroll :: any
end

function MenuController:Start()
	self:_build()

	Net.Event("QuestsChanged").OnClientEvent:Connect(function(view: any)
		if type(view) == "table" then
			quests = view
			if isOpen and activeTab == "Quests" then
				self:_refresh()
			end
		end
	end)

	ProfileController.Changed:Connect(function()
		if isOpen and (activeTab == "Upgrades" or activeTab == "Shop" or activeTab == "Map") then
			self:_refresh()
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end
		-- M toggles; Escape only closes, so it never opens the menu by accident.
		local isToggle = input.KeyCode == Enum.KeyCode.M
		local isClose = input.KeyCode == Enum.KeyCode.Escape and isOpen
		if isToggle or isClose then
			self:Toggle()
		end
	end)
end

return MenuController
