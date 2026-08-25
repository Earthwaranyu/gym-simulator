--!strict
--[[
	MenuController — the Info, Shop and Settings menu plus standalone text panels.

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
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local ReputationConfig = require(ReplicatedStorage.Modules.ReputationConfig)
local Icons = require(ReplicatedStorage.Modules.Icons)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local MapRender = require(ReplicatedStorage.Modules.MapRender)
local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)
local ShopIcons = require(ReplicatedStorage.Modules.ShopIcons)
local TokenMultiplierConfig = require(ReplicatedStorage.Modules.TokenMultiplierConfig)
local MuscleIcons = require(ReplicatedStorage.Modules.MuscleIcons)

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
local bodyScroll: ScrollingFrame
local titleLabel: TextLabel
local tabStrip: Frame
local tabButtons: { [string]: TextButton } = {}
local isOpen = false
local activeTab = "Info"
local quests: { any } = {}

type Destination = MapRender.Destination

-- All training locations come from the server because StreamingEnabled means
-- most physical stations do not exist in the spawn client's Workspace yet.
-- MapRender owns the round-trip and caches it, so the HUD's minimap and this screen
-- share one answer rather than asking the same question twice.
local destinations: { Destination } = {}
local mapFeatures: { MapRender.Feature } = {}
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

-- The map's paper palette lives in MapRender, so the minimap in the HUD and this board
-- cannot drift into being two different-looking maps of the same city.
--[[
	The panel's header band, in pixels.

	CLOSE_SIZE is the close button, which sits in the top-right corner; HEADER_BAND is
	how far down a page's content has to start to clear it. They were bare numbers
	inside the layout code, and the standalone pages were using the button's height as
	their content offset — which put the first card's corner flush against the button
	with no gap at all.
]]
local CLOSE_SIZE = 28
local HEADER_BAND = CLOSE_SIZE + 10
-- Tabbed pages clear the header and the tab strip under it.
local TABBED_BAND = 82

local MAP_PAPER = MapRender.Paper
local MAP_INK = MapRender.Ink

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

local wash = MapRender.Tint

local function statValue(data: any?, statId: string): number
	return if data ~= nil then (data.Stats[statId] or 0) else 0
end

local function destinationUnlocked(data: any?, destination: Destination): boolean
	return statValue(data, destination.StatId) >= destination.RequiredStat
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
	btn.TextColor3 = UI.Palette.OnAccent
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

	-- Three tabs, not seven.
	--
	-- The seven-tab strip put Map, Train, Upgrades, Quests, Shop, Top and Settings
	-- behind one button, which meant the two screens a player opens constantly — the
	-- map and their own stats — were the same number of clicks away as the ones they
	-- open twice a session. The interactive map now belongs to FullMapController;
	-- Ranks and Quests remain direct HUD routes. What is left here is genuinely a
	-- menu: who you are, what you can buy, and what you can switch off.
	tabs = {
		{
			Id = "Info",
			DisplayName = "Info",
			Render = function(parent)
				self:_renderInfo(parent)
			end,
		},
		{
			Id = "Muscles",
			DisplayName = "Muscles",
			Icon = "Train",
			Render = function(parent)
				self:_renderMuscleClasses(parent)
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
			Id = "Settings",
			DisplayName = "Settings",
			Render = function(parent)
				self:_renderSettings(parent)
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
			Id = "Titles",
			DisplayName = "Titles",
			Icon = "Rank",
			OnBar = false,
			Render = function(parent)
				self:_renderTitles(parent)
			end,
		},
		{
			Id = "Ranks",
			DisplayName = "Top",
			Icon = "Top",
			OnBar = false,
			Render = function(parent)
				self:_renderLeaderboard(parent)
			end,
		},
	}
end

-- Pull every map-enabled training station from the server once.
function MenuController:_fetchDestinations()
	destinations, mapFeatures = MapRender.Fetch()
end

-- Every training location appears immediately. Pin colour is the stat; locked
-- pins stay visible but dim so the map shows both where to go and what to grind for.
function MenuController:_renderMap(parent: Frame)
	self:_fetchDestinations()

	local data = ProfileController:Get()

	if selectedDestination == nil then
		for _, destination in destinations do
			if destinationUnlocked(data, destination) then
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

	-- Bounds and projection are MapRender's, letterboxed to this board's aspect so the
	-- whole archipelago fits without cropping an island.
	local bounds = MapRender.Bounds(mapFeatures, destinations, MAP_ASPECT)
	local project = MapRender.Project(bounds)

	local viewport = Instance.new("ScrollingFrame")
	viewport.Name = "MapViewport"
	viewport.Active = true
	viewport.BackgroundColor3 = UI.Palette.Backdrop
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

	MapRender.DrawFeatures(featureLayer, mapFeatures, bounds)

	local hub = UI.Label("Hub", pinLayer)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(74, 16)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.TextSize = 11
	hub.TextColor3 = UI.Palette.Token
	hub.Text = "SPAWN"
	hub.ZIndex = 24

	local unlockedCount = 0
	for _, destination in destinations do
		local stat = StatConfig.Get(destination.StatId)
		if stat == nil then
			continue
		end

		local unlocked = destinationUnlocked(data, destination)
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
		pinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
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

	self:_renderDestination(parent, data)

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

	-- The muscle picker and its station list, which used to be a Train tab of its
	-- own. "Where do I train Back" is a question about the map, so it is answered on
	-- the map rather than one screen away from it — and the stat slots along the
	-- bottom of the HUD no longer open anything, so this is the only route to it.
	self:_renderTrain(parent, 10)
end

-- The selected machine, its stat, tier multiplier and travel button.
function MenuController:_renderDestination(parent: Frame, data: any?)
	local destination = if selectedDestination ~= nil
		then MapRender.GetDestination(selectedDestination)
		else nil
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

	local shortfall = destination.RequiredStat - statValue(data, destination.StatId)
	if shortfall > 0 then
		detail.Text = `<font color="#FF5C5C">Needs {NumberFormat.Format(shortfall)} more {stat.DisplayName}</font>`
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
		while token == trainPollToken and isOpen and activeTab == "Map" do
			task.wait(2)
			if token ~= trainPollToken or not isOpen or activeTab ~= "Map" then
				return
			end
			self:_fetchSpotStatus()
			if token == trainPollToken and isOpen and activeTab == "Map" then
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
--
-- `baseOrder` shifts every LayoutOrder this function assigns. It exists because the
-- panel is now shared with the map above it: without the offset the muscle chips
-- (order 1) would sort into the same slot as the map board and the two sections
-- would interleave.
function MenuController:_renderTrain(parent: Frame, baseOrder: number?)
	local base = baseOrder or 0
	self:_fetchDestinations()

	local data = ProfileController:Get()

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
	chips.LayoutOrder = base + 1
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
		chip.TextColor3 = if selected then UI.Palette.OnAccent else definition.Color
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
			Unlocked = destinationUnlocked(data, destination),
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
		return a.Destination.RequiredStat < b.Destination.RequiredStat
	end)

	local summary = UI.Label("Summary", parent)
	summary.Size = UDim2.new(1, 0, 0, 20)
	summary.LayoutOrder = base + 2
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
		empty.LayoutOrder = base + 3
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "The map is still loading."
		return
	end

	for index, spot in spots do
		local destination = spot.Destination
		local status = spotStatus[destination.Id]
		local here = currentSpotId == destination.Id

		local line = row(parent, 54, base + index + 3)

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
			local shortfall = destination.RequiredStat - statValue(data, destination.StatId)
			detail.Text = `<font color="#FF5C5C">needs {NumberFormat.Format(shortfall)} more {stat.DisplayName}</font>`
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

-- Opens the dedicated map on a useful destination for one muscle. The route stays
-- here for callers written before the map became its own controller.
function MenuController:OpenTrain(statId: string)
	if StatConfig.Get(statId) == nil then
		warn(`[MenuController] No stat named "{statId}"`)
		return
	end
	selectedMuscle = statId
	Loader.Get("FullMapController"):OpenForStat(statId)
end

--[[
	Info — the character sheet, and the multiplier shop that used to be its own tab.

	Who you are and what you are buying belong on one screen: every row here is a
	stat, its current worth, and the price of doubling it. Splitting them meant
	reading a number on one tab and paying for it on another.
]]
function MenuController:_renderInfo(parent: Frame)
	local data = ProfileController:Get()
	local stats = if data ~= nil then data.Stats else {}
	local power = Formulas.TotalPower(stats)
	local rank = RankConfig.Get(power)
	local reputation = ReputationConfig.Get(if data ~= nil then data.Reputation else 0)

	local header = UI.CartoonCard("ProfileHero", rank.Color, parent)
	header.Size = UDim2.new(1, 0, 0, 64)
	header.LayoutOrder = 1

	local portrait = Instance.new("ImageLabel")
	portrait.Name = "Portrait"
	portrait.AnchorPoint = Vector2.new(0, 0.5)
	portrait.Position = UDim2.new(0, 8, 0.5, 0)
	portrait.Size = UDim2.fromOffset(48, 48)
	portrait.BackgroundColor3 = UI.Palette.Backdrop
	portrait.BorderSizePixel = 0
	portrait.ScaleType = Enum.ScaleType.Crop
	portrait.Parent = header

	local portraitAspect = Instance.new("UIAspectRatioConstraint")
	portraitAspect.AspectRatio = 1
	portraitAspect.Parent = portrait

	local portraitCorner = Instance.new("UICorner")
	portraitCorner.CornerRadius = UDim.new(0, 6)
	portraitCorner.Parent = portrait

	local portraitStroke = Instance.new("UIStroke")
	portraitStroke.Color = rank.Color
	portraitStroke.Thickness = 1
	portraitStroke.Parent = portrait

	task.spawn(function()
		local ok, image = pcall(function()
			return Players:GetUserThumbnailAsync(
				Players.LocalPlayer.UserId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size150x150
			)
		end)
		if ok and portrait.Parent ~= nil then
			portrait.Image = image
		end
	end)

	local name = UI.Label("Name", header)
	name.Size = UDim2.new(0.5, -74, 0, 22)
	name.Position = UDim2.fromOffset(68, 6)
	name.Font = Enum.Font.GothamBold
	name.TextSize = 17
	name.TextColor3 = UI.Palette.Text
	name.Text = Players.LocalPlayer.DisplayName

	local rankLabel = UI.Label("Rank", header)
	rankLabel.Size = UDim2.new(0.5, -74, 0, 18)
	rankLabel.Position = UDim2.fromOffset(68, 27)
	rankLabel.Font = UI.Font.Heading
	rankLabel.TextSize = 12
	rankLabel.TextColor3 = UI.Palette.Text
	rankLabel.Text = `{rank.DisplayName}  ·  {reputation.DisplayName}`

	local record = UI.Label("Record", header)
	record.Size = UDim2.new(0.5, -74, 0, 16)
	record.Position = UDim2.fromOffset(68, 44)
	record.Font = UI.Font.Heading
	record.TextSize = 11
	record.TextColor3 = UI.Palette.Text
	record.Text =
		`{if data ~= nil then data.Kills else 0} KOs  ·  {if data ~= nil then data.Deaths else 0} downs`

	local heroPower = UI.Label("Power", header)
	heroPower.AnchorPoint = Vector2.new(1, 0)
	heroPower.Position = UDim2.new(1, -12, 0, 7)
	heroPower.Size = UDim2.new(0.48, -10, 0, 28)
	heroPower.Font = UI.Font.Numeric
	heroPower.TextSize = 21
	heroPower.TextXAlignment = Enum.TextXAlignment.Right
	heroPower.TextColor3 = UI.Palette.Power
	heroPower.Text = `{NumberFormat.FormatGain(power)} POWER`

	local heroTokens = UI.Label("Tokens", header)
	heroTokens.AnchorPoint = Vector2.new(1, 0)
	heroTokens.Position = UDim2.new(1, -12, 0, 32)
	heroTokens.Size = UDim2.new(0.48, -10, 0, 15)
	heroTokens.Font = Enum.Font.GothamBold
	heroTokens.TextSize = 11
	heroTokens.TextXAlignment = Enum.TextXAlignment.Right
	heroTokens.TextColor3 = UI.Palette.Token
	heroTokens.Text = `{NumberFormat.Format(if data ~= nil then data.Tokens else 0)} TRAINING TOKENS`

	local heroFightTokens = UI.Label("FightTokens", header)
	heroFightTokens.AnchorPoint = Vector2.new(1, 0)
	heroFightTokens.Position = UDim2.new(1, -12, 0, 47)
	heroFightTokens.Size = UDim2.new(0.48, -10, 0, 15)
	heroFightTokens.Font = Enum.Font.GothamBold
	heroFightTokens.TextSize = 11
	heroFightTokens.TextXAlignment = Enum.TextXAlignment.Right
	heroFightTokens.TextColor3 = UI.Palette.FightToken
	heroFightTokens.Text = `{NumberFormat.Format(if data ~= nil then data.FightTokens else 0)} FIGHT TOKENS`

	-- Five equal rows mirror the five-slot training dock. They deliberately fit in the
	-- fixed body height, so the character sheet never hides Legs below a scrollbar.
	local statList = Instance.new("Frame")
	statList.Name = "StatList"
	statList.BackgroundTransparency = 1
	statList.Size = UDim2.new(1, 0, 0, 335)
	statList.LayoutOrder = 2
	statList.Parent = parent

	local listLayout = UI.VerticalList(statList, 5)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder

	local function statCard(definition: StatConfig.StatDefinition, index: number)
		local level = if data ~= nil then (data.MultiplierLevels[definition.Id] or 0) else 0
		local currentMultiplier = TokenMultiplierConfig.Get(level)
		local nextMultiplier = TokenMultiplierConfig.Next(level)
		local card = UI.CartoonCard(definition.Id, definition.Color, statList)
		card.LayoutOrder = index
		card.Size = UDim2.new(1, 0, 0, 63)

		local glyphHolder = Instance.new("Frame")
		glyphHolder.Name = "Glyph"
		glyphHolder.BackgroundColor3 = UI.Palette.Backdrop
		glyphHolder.BackgroundTransparency = 0.3
		glyphHolder.BorderSizePixel = 0
		glyphHolder.AnchorPoint = Vector2.new(0, 0.5)
		glyphHolder.Position = UDim2.new(0, 8, 0.5, 0)
		glyphHolder.Size = UDim2.fromOffset(48, 48)
		glyphHolder.Parent = card

		local glyphCorner = Instance.new("UICorner")
		glyphCorner.CornerRadius = UDim.new(0, 6)
		glyphCorner.Parent = glyphHolder

		local glyphAspect = Instance.new("UIAspectRatioConstraint")
		glyphAspect.AspectRatio = 1
		glyphAspect.Parent = glyphHolder

		local glyphPadding = Instance.new("UIPadding")
		glyphPadding.PaddingTop = UDim.new(0, 8)
		glyphPadding.PaddingBottom = UDim.new(0, 8)
		glyphPadding.PaddingLeft = UDim.new(0, 8)
		glyphPadding.PaddingRight = UDim.new(0, 8)
		glyphPadding.Parent = glyphHolder
		Icons.Draw(definition.Icon, glyphHolder, definition.Color, UI.Palette.Backdrop)

		local label = UI.Label("Name", card)
		label.Position = UDim2.fromOffset(68, 6)
		label.Size = UDim2.fromOffset(146, 20)
		label.Font = Enum.Font.GothamBold
		label.TextSize = 14
		label.TextColor3 = definition.Color
		label.Text = string.upper(definition.DisplayName)

		local value = UI.Label("Value", card)
		value.Position = UDim2.fromOffset(68, 26)
		value.Size = UDim2.fromOffset(132, 32)
		value.Font = UI.Font.Numeric
		value.TextSize = 20
		value.TextColor3 = UI.Palette.Text
		value.Text = NumberFormat.FormatGain(stats[definition.Id] or 0)

		local effect = UI.Label("Effect", card)
		effect.AnchorPoint = Vector2.new(0, 0.5)
		effect.Position = UDim2.new(0, 210, 0.5, 0)
		effect.Size = UDim2.new(1, -360, 0, 30)
		effect.Font = UI.Font.Heading
		effect.TextSize = 13
		effect.TextColor3 = UI.Palette.Text
		effect.TextTruncate = Enum.TextTruncate.AtEnd
		effect.Text = definition.Effect(stats)

		local multiplier = UI.Label("Multiplier", card)
		multiplier.AnchorPoint = Vector2.new(1, 0.5)
		multiplier.Position = UDim2.new(1, -60, 0.5, 0)
		multiplier.Size = UDim2.fromOffset(82, 30)
		multiplier.Font = UI.Font.Numeric
		multiplier.TextSize = 18
		multiplier.TextXAlignment = Enum.TextXAlignment.Right
		multiplier.TextColor3 = UI.Palette.Token
		multiplier.Text = `×{NumberFormat.FormatGain(currentMultiplier.Multiplier)}`

		local upgrade = Instance.new("TextButton")
		upgrade.Name = "Upgrade"
		upgrade.AnchorPoint = Vector2.new(1, 0.5)
		upgrade.Position = UDim2.new(1, -10, 0.5, 0)
		upgrade.Size = UDim2.fromOffset(38, 38)
		upgrade.BackgroundColor3 = if nextMultiplier ~= nil
			then UI.Palette.FightToken
			else UI.Palette.Backdrop
		upgrade.BorderSizePixel = 0
		upgrade.AutoButtonColor = false
		upgrade.Font = Enum.Font.GothamBold
		upgrade.TextSize = 24
		upgrade.TextColor3 = UI.Palette.OnAccent
		upgrade.Text = if nextMultiplier ~= nil then "+" else "✓"
		upgrade.Active = nextMultiplier ~= nil
		upgrade.Parent = card

		local upgradeCorner = Instance.new("UICorner")
		upgradeCorner.CornerRadius = UDim.new(1, 0)
		upgradeCorner.Parent = upgrade

		local upgradeStroke = Instance.new("UIStroke")
		upgradeStroke.Color = if nextMultiplier ~= nil then UI.Palette.Accent else UI.Palette.GlassStroke
		upgradeStroke.Thickness = 1
		upgradeStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		upgradeStroke.Parent = upgrade

		if nextMultiplier ~= nil then
			UI.Pressable(upgrade, { PressScale = 0.94, HoverScale = 1.03 })
			upgrade.Activated:Connect(function()
				UI.Confirm(screen, {
					Title = `Upgrade {definition.DisplayName} Multiplier`,
					Body = `Spend {NumberFormat.Format(nextMultiplier.CostToUnlock)} tokens to raise {definition.DisplayName} gains from ×{NumberFormat.FormatGain(
						currentMultiplier.Multiplier
					)} to ×{NumberFormat.FormatGain(nextMultiplier.Multiplier)}?`,
					ConfirmText = `UPGRADE TO ×{NumberFormat.FormatGain(nextMultiplier.Multiplier)}`,
					CancelText = "Cancel",
					OnConfirm = function()
						local ok, message = Net.Function("PurchaseMultiplier"):InvokeServer(definition.Id)
						toast(message)
						if ok then
							Loader.Get("EffectsController"):Play("Purchase")
							self:_refresh()
						end
					end,
				})
			end)
		end
	end

	for index, definition in StatConfig.List do
		statCard(definition, index)
	end
end

function MenuController:_renderMuscleClasses(parent: Frame)
	local data = ProfileController:Get()
	local currentLevel =
		math.clamp(if data ~= nil then data.MuscleClassLevel else 0, 0, MuscleClassConfig.MAX_LEVEL)
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
	local fightTokens = if data ~= nil then data.FightTokens else 0
	local nextClass = MuscleClassConfig.Next(currentLevel)

	local intro = UI.Label("Intro", parent)
	intro.Size = UDim2.new(1, 0, 0, 58)
	intro.LayoutOrder = 1
	intro.TextWrapped = true
	intro.TextSize = 13
	intro.TextColor3 = UI.Palette.TextMuted
	intro.Text =
		`PHYSIQUE TRANSFORMATION · YOU HAVE {NumberFormat.Format(fightTokens)} FIGHT TOKENS · Every stat, token and multiplier stays. Your body takes the new class colour and returns lean, ready to visibly build each muscle again.`

	for _, class in MuscleClassConfig.List do
		local current = class.Level == currentLevel
		local previouslyUnlocked = class.Level < currentLevel
		local isNext = nextClass ~= nil and class.Level == nextClass.Level
		local powerReady = power >= class.RequiredPower
		local tokensReady = fightTokens >= class.FightTokenCost
		local eligible = isNext and powerReady and tokensReady
		local accent = MuscleClassConfig.Color(class.Level)
		-- The class colours are the physique tints the avatar itself is painted with,
		-- so they are chosen to read on a body rather than as type on paper, and the
		-- early ones are pale enough to vanish on the cream card. Darkened here, at
		-- the one place they are used as text, rather than in the config — moving them
		-- there would repaint every dummy in the game.
		local accentInk = accent:Lerp(UI.Palette.Text, 0.45)
		local card = UI.CartoonCard(`Class{class.Level}`, accent, parent)
		card.LayoutOrder = 10 + class.Level
		-- Taller than the quest cards beside it because it carries one line more: the
		-- token rate the class earns, under the power and the price it costs.
		card.Size = UDim2.new(1, 0, 0, 118)
		card.BackgroundTransparency = 0.04

		local preview = Instance.new("Frame")
		preview.Name = "Preview"
		preview.Position = UDim2.fromOffset(8, 8)
		preview.Size = UDim2.fromOffset(88, 88)
		preview.BackgroundColor3 = UI.Palette.Backdrop
		preview.BackgroundTransparency = 0.2
		preview.BorderSizePixel = 0
		preview.Parent = card
		local previewCorner = Instance.new("UICorner")
		previewCorner.CornerRadius = UDim.new(0, 9)
		previewCorner.Parent = preview
		local figure = MuscleIcons.Build(preview, "Overall", accent)
		if figure ~= nil then
			figure.SetFlex(class.Level / MuscleClassConfig.MAX_LEVEL)
		end

		local title = UI.Label("ClassName", card)
		title.Position = UDim2.fromOffset(108, 12)
		title.Size = UDim2.new(1, -300, 0, 24)
		title.Font = UI.Font.Heading
		title.TextSize = 16
		title.TextColor3 = accentInk
		title.Text = `CLASS {class.Level + 1} · {string.upper(class.DisplayName)}`

		local multiplier = UI.Label("Multiplier", card)
		multiplier.Position = UDim2.fromOffset(108, 39)
		multiplier.Size = UDim2.new(1, -300, 0, 23)
		multiplier.Font = UI.Font.Numeric
		multiplier.TextSize = 19
		multiplier.TextColor3 = UI.Palette.Text
		multiplier.Text = if class.Level == 0
			then "STARTING PHYSIQUE"
			else `{NumberFormat.Format(class.RequiredPower)} POWER · {NumberFormat.Format(
				class.FightTokenCost
			)} FIGHT TOKENS`

		-- The reason to buy one. A class doubles the playtime token tick, and none of
		-- this screen said so — it read as a price for a colour.
		local rate = UI.Label("Rate", card)
		rate.Position = UDim2.fromOffset(108, 90)
		rate.Size = UDim2.new(1, -300, 0, 18)
		rate.Font = UI.Font.Heading
		rate.TextSize = 11
		rate.TextColor3 = accentInk
		rate.Text = `×{NumberFormat.Format(class.TokenMultiplier)} TOKENS WHILE YOU PLAY`

		local detail = UI.Label("Detail", card)
		detail.Position = UDim2.fromOffset(108, 67)
		detail.Size = UDim2.new(1, -300, 0, 20)
		detail.TextSize = 12
		detail.TextColor3 = UI.Palette.TextMuted
		detail.Text = if current
			then "CURRENT · permanent physique class"
			elseif previouslyUnlocked then "COMPLETED · permanent"
			elseif isNext and eligible then "READY · token multipliers will be kept"
			elseif
				isNext and not powerReady
			then `NEED {NumberFormat.Format(class.RequiredPower - power)} MORE POWER`
			elseif
				isNext
			then `NEED {NumberFormat.Format(class.FightTokenCost - fightTokens)} MORE FIGHT TOKENS`
			else `LOCKED · transform into class {class.Level} first`

		local action = Instance.new("TextButton")
		action.Name = "Action"
		action.AnchorPoint = Vector2.new(1, 0.5)
		action.Position = UDim2.new(1, -10, 0.5, 0)
		action.Size = UDim2.fromOffset(178, 48)
		action.BackgroundColor3 = if eligible then UI.Palette.Token else UI.Palette.Backdrop
		action.BackgroundTransparency = if eligible then 0 else 0.35
		action.BorderSizePixel = 0
		action.Font = UI.Font.Heading
		action.TextSize = 12
		action.TextColor3 = if eligible then UI.Palette.CartoonInk else UI.Palette.TextMuted
		action.Text = if current
			then "CURRENT"
			elseif previouslyUnlocked then "COMPLETED"
			elseif eligible then "TRANSFORM"
			elseif isNext and not powerReady then "POWER LOCKED"
			elseif isNext then "TOKEN LOCKED"
			else "ORDER LOCKED"
		action.Active = eligible
		action.Parent = card
		local actionCorner = Instance.new("UICorner")
		actionCorner.CornerRadius = UDim.new(0, 9)
		actionCorner.Parent = action
		if action.Active then
			UI.Pressable(action)
			action.Activated:Connect(function()
				UI.Confirm(screen, {
					Title = `Transform into {class.DisplayName}?`,
					Body = `Spend {NumberFormat.Format(class.FightTokenCost)} Fight Tokens to unlock the {class.DisplayName} physique? You will earn ×{NumberFormat.Format(
						class.TokenMultiplier
					)} tokens for time played from then on. Your power is safe. Your appearance becomes lean in the new class colour, then Arms, Chest, Back, Core and Legs grow again only when you train that group.`,
					ConfirmText = "TRANSFORM",
					CancelText = "Cancel",
					OnConfirm = function()
						local ok, message = Net.Function("SelectPhysiqueClass"):InvokeServer(class.Level)
						toast(message)
						if ok then
							self:_refresh()
						end
					end,
				})
			end)
		end
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
		local progress = if type(quest.Progress) == "number" then math.max(0, quest.Progress) else 0
		local goal = if type(quest.Goal) == "number" then math.max(1, quest.Goal) else 1
		local complete = quest.Complete == true
		local accent = if complete
			then UI.Palette.Vital
			elseif quest.Id == "CycleMobHunt" then UI.Palette.Danger
			elseif quest.Id == "CycleUpperBody" then UI.Palette.Power
			else UI.Palette.Token

		local card = UI.CartoonCard(tostring(quest.Id), accent, parent)
		card.LayoutOrder = index
		card.Size = UDim2.new(1, 0, 0, 104)

		local iconBubble = Instance.new("Frame")
		iconBubble.Name = "Icon"
		iconBubble.Position = UDim2.fromOffset(10, 10)
		iconBubble.Size = UDim2.fromOffset(54, 54)
		iconBubble.BackgroundColor3 = UI.Palette.CartoonInk
		iconBubble.BackgroundTransparency = 0.12
		iconBubble.BorderSizePixel = 0
		iconBubble.Parent = card

		local iconCorner = Instance.new("UICorner")
		iconCorner.CornerRadius = UDim.new(1, 0)
		iconCorner.Parent = iconBubble

		local iconPadding = Instance.new("UIPadding")
		iconPadding.PaddingTop = UDim.new(0, 10)
		iconPadding.PaddingBottom = UDim.new(0, 10)
		iconPadding.PaddingLeft = UDim.new(0, 10)
		iconPadding.PaddingRight = UDim.new(0, 10)
		iconPadding.Parent = iconBubble
		Icons.Draw("Quest", iconBubble, UI.Palette.CartoonCream, UI.Palette.CartoonInk)

		local name = UI.Label("Name", card)
		name.Position = UDim2.fromOffset(76, 8)
		name.Size = UDim2.new(1, -238, 0, 24)
		name.Font = UI.Font.Heading
		name.TextSize = 16
		name.TextColor3 = UI.Palette.Text
		name.Text = string.upper(tostring(quest.DisplayName))

		local detail = UI.Label("Description", card)
		detail.Position = UDim2.fromOffset(76, 31)
		detail.Size = UDim2.new(1, -88, 0, 32)
		detail.TextSize = 13
		detail.TextColor3 = UI.Palette.Text
		detail.TextWrapped = true
		detail.Text = tostring(quest.Description)

		local reward = UI.Label("Reward", card)
		reward.AnchorPoint = Vector2.new(1, 0)
		reward.Position = UDim2.new(1, -10, 0, 9)
		reward.Size = UDim2.fromOffset(146, 24)
		reward.BackgroundColor3 = if complete then UI.Palette.Vital else UI.Palette.CartoonCream
		reward.BackgroundTransparency = 0
		reward.Font = UI.Font.Heading
		reward.TextSize = 12
		-- Completed fills the chip with the dark Vital green, so the label has to
		-- flip to the light ink or it disappears into its own badge.
		reward.TextColor3 = if complete then UI.Palette.OnAccent else UI.Palette.CartoonInk
		reward.TextXAlignment = Enum.TextXAlignment.Center
		reward.Text = if complete then "COMPLETED" else `+{quest.TokenReward} TOKENS`

		local rewardCorner = Instance.new("UICorner")
		rewardCorner.CornerRadius = UDim.new(0, 7)
		rewardCorner.Parent = reward

		local progressBar = UI.Bar("Progress", accent, card)
		progressBar.Root.Position = UDim2.fromOffset(10, 72)
		progressBar.Root.Size = UDim2.new(1, -20, 0, 22)
		local unit = if quest.Id == "DailyKnockouts" then "KOs" else "POWER"
		progressBar.Set(
			math.clamp(progress / goal, 0, 1),
			if complete
				then `COMPLETE  ·  {NumberFormat.Format(goal)} {unit}`
				else `{NumberFormat.Format(progress)} / {NumberFormat.Format(goal)} {unit}`
		)
	end
end

-- Which catalogue rows belong on the supplements shelf. An explicit set because these
-- used to be recognised by having a ShopConfig entry, and that config went with the
-- token-priced shelf; a new supplement is one id here plus its product file.
local SUPPLEMENT_IDS: { [string]: boolean } = {
	PreWorkout = true,
	ProteinShake = true,
}

--[[
	Shop — the Robux catalogue, in headed sections you scroll through.

	The Robux rows come from the server's product registry rather than from a table
	here, so a new file in PurchaseService/Products appears in this list with no
	client edit. The server also decides what is available: an unconfigured AssetId
	reports as unavailable here instead of being offered and then refused after the
	player has already committed to buying it.
]]
function MenuController:_renderShop(parent: Frame)
	local ok, catalogue = pcall(function()
		return Net.Function("GetProductCatalogue"):InvokeServer()
	end)

	local sections: { [string]: { any } } = { Gamepass = {}, Potion = {}, Supplement = {}, Token = {} }
	if ok and type(catalogue) == "table" then
		for _, product in catalogue do
			-- Grouped by what the thing is to the player, not by Roblox's product
			-- kind: a potion and a token pack are both DevProducts and belong in
			-- different parts of a shop.
			-- Supplements keep their own row rather than sitting under the immortality
			-- potions, which was never true of them. Named explicitly: they used to be
			-- recognised by having a ShopConfig entry, and that file is gone with the
			-- token-priced shelf.
			local group = if product.Kind == "Gamepass"
				then "Gamepass"
				elseif string.find(tostring(product.Id), "TokenPack") ~= nil then "Token"
				elseif SUPPLEMENT_IDS[tostring(product.Id)] then "Supplement"
				else "Potion"
			table.insert(sections[group], product)
		end
	end

	-- VIP is the game's flagship pass and should be read first. Catalogue prices are
	-- sorted server-side, which otherwise puts the cheaper Fast Travel card before it.
	local gamepassOrder: { [string]: number } = { Vip = 1, AutoLoad = 2, FastTravel = 3 }
	table.sort(sections.Gamepass, function(left, right): boolean
		local leftOrder = gamepassOrder[tostring(left.Id)] or 100
		local rightOrder = gamepassOrder[tostring(right.Id)] or 100
		if leftOrder ~= rightOrder then
			return leftOrder < rightOrder
		end
		return tostring(left.Id) < tostring(right.Id)
	end)

	local order = 0

	local function productCard(
		grid: Frame,
		layoutOrder: number,
		title: string,
		description: string,
		iconName: string,
		accent: Color3,
		actionText: string,
		enabled: boolean,
		onClick: () -> (),
		-- Drawn in the corner regardless of what the button says. The button reads
		-- OWNED once a pass is bought, and that used to be the only place a price
		-- appeared — so an owner, the developer included, could never see what their
		-- own pass costs.
		priceText: string?
	)
		local card = UI.CartoonCard(title, accent, grid)
		card.LayoutOrder = layoutOrder

		local iconBubble = Instance.new("Frame")
		iconBubble.Name = "Icon"
		iconBubble.Position = UDim2.fromOffset(10, 12)
		iconBubble.Size = UDim2.fromOffset(62, 62)
		iconBubble.BackgroundColor3 = UI.Palette.CartoonInk
		iconBubble.BackgroundTransparency = 0.12
		iconBubble.BorderSizePixel = 0
		iconBubble.Parent = card

		local iconAspect = Instance.new("UIAspectRatioConstraint")
		iconAspect.AspectRatio = 1
		iconAspect.Parent = iconBubble

		local iconCorner = Instance.new("UICorner")
		iconCorner.CornerRadius = UDim.new(1, 0)
		iconCorner.Parent = iconBubble

		local iconPadding = Instance.new("UIPadding")
		iconPadding.PaddingTop = UDim.new(0, 10)
		iconPadding.PaddingBottom = UDim.new(0, 10)
		iconPadding.PaddingLeft = UDim.new(0, 10)
		iconPadding.PaddingRight = UDim.new(0, 10)
		iconPadding.Parent = iconBubble
		Icons.Draw(iconName, iconBubble, UI.Palette.CartoonCream, UI.Palette.CartoonInk)

		local name = UI.Label("Name", card)
		name.Position = UDim2.fromOffset(82, 10)
		name.Size = UDim2.new(1, -92, 0, 22)
		name.Font = UI.Font.Heading
		name.TextSize = 14
		name.TextColor3 = UI.Palette.Text
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = string.upper(title)

		if priceText ~= nil then
			local price = UI.Label("Price", card)
			price.AnchorPoint = Vector2.new(1, 0)
			price.Position = UDim2.new(1, -10, 0, 10)
			price.Size = UDim2.fromOffset(64, 22)
			price.Font = UI.Font.Heading
			price.TextSize = 12
			price.TextXAlignment = Enum.TextXAlignment.Right
			price.TextColor3 = accent
			price.Text = priceText
			-- The name shares this row, so it yields the width the price takes.
			name.Size = UDim2.new(1, -160, 0, 22)
		end

		local detail = UI.Label("Description", card)
		detail.Position = UDim2.fromOffset(82, 32)
		detail.Size = UDim2.new(1, -92, 0, 38)
		detail.TextSize = 11
		detail.TextColor3 = UI.Palette.Text
		detail.TextWrapped = true
		detail.TextYAlignment = Enum.TextYAlignment.Top
		detail.TextTruncate = Enum.TextTruncate.AtEnd
		detail.Text = description

		local action = Instance.new("TextButton")
		action.Name = "Buy"
		action.Position = UDim2.fromOffset(10, 78)
		action.Size = UDim2.new(1, -20, 0, 26)
		action.BackgroundColor3 = if enabled then UI.Palette.CartoonCream else UI.Palette.TextMuted
		action.BackgroundTransparency = if enabled then 0 else 0.28
		action.BorderSizePixel = 0
		action.AutoButtonColor = false
		action.Font = UI.Font.Heading
		action.TextSize = 12
		action.TextColor3 = UI.Palette.CartoonInk
		action.Text = actionText
		action.Parent = card

		local actionCorner = Instance.new("UICorner")
		actionCorner.CornerRadius = UDim.new(0, 8)
		actionCorner.Parent = action

		local actionStroke = Instance.new("UIStroke")
		actionStroke.Color = UI.Palette.CartoonInk
		actionStroke.Thickness = 2
		actionStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		actionStroke.Parent = action

		if enabled then
			UI.Pressable(action, { PressScale = 0.95, HoverScale = 1.02 })
			action.Activated:Connect(onClick)
		end
	end

	local function section(
		title: string,
		detail: string,
		accent: Color3,
		count: number,
		render: (Frame) -> ()
	)
		if count == 0 then
			return
		end

		order += 1
		local rows = math.ceil(count / 2)
		local root = Instance.new("Frame")
		root.Name = title
		root.BackgroundTransparency = 1
		root.Size = UDim2.new(1, 0, 0, 42 + rows * 118)
		root.LayoutOrder = order
		root.Parent = parent

		local heading = UI.Label("Heading", root)
		heading.Size = UDim2.new(1, 0, 0, 38)
		heading.Font = UI.Font.Heading
		heading.TextSize = 16
		heading.TextColor3 = accent
		heading.Text = `{string.upper(title)}\n<font color="#AEB6CC" size="11">{detail}</font>`

		local grid = Instance.new("Frame")
		grid.Name = "Cards"
		grid.Position = UDim2.fromOffset(0, 42)
		grid.Size = UDim2.new(1, 0, 0, rows * 118)
		grid.BackgroundTransparency = 1
		grid.Parent = root

		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.new(0.5, -5, 0, 108)
		layout.CellPadding = UDim2.fromOffset(10, 10)
		layout.FillDirectionMaxCells = 2
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = grid

		render(grid)
	end

	local groupVisuals = {
		Gamepass = {
			Title = "VIP & PASSES",
			Detail = "Permanent perks for serious lifters",
			Accent = UI.Palette.Accent,
			Icon = "Vip",
		},
		Potion = {
			Title = "IMMORTAL POTIONS",
			Detail = "A glowing shield while you train",
			Accent = UI.Palette.CartoonPink,
			Icon = "Potion",
		},
		Supplement = {
			Title = "SUPPLEMENTS",
			Detail = "Temporary boosts, bought outright",
			Accent = UI.Palette.CartoonPink,
			Icon = "Potion",
		},
		Token = {
			Title = "TOKEN DUMBBELLS",
			Detail = "Permanent multiplier currency",
			Accent = UI.Palette.Token,
			Icon = "Token",
		},
	}

	for _, group in { "Gamepass", "Potion", "Supplement", "Token" } do
		local products = sections[group]
		local visual = groupVisuals[group]
		section(visual.Title, visual.Detail, visual.Accent, #products, function(grid)
			for index, product in products do
				local enabled = product.Available and not product.Owned
				-- The price rides the button wherever the button has room for it. It
				-- moves to the corner label only when the button is already spent on
				-- OWNED or COMING SOON — so a price is always on the card, never twice.
				local sellable = not product.Owned and product.Available
				local priceText = `R$ {NumberFormat.Format(product.RobuxPrice)}`
				local actionText = if product.Owned
					then "OWNED"
					elseif not product.Available then "COMING SOON"
					else `BUY  ·  {priceText}`
				-- The dashboard icon if the product has one, then any artwork bundled
				-- with the game, then the shelf's shared glyph.
				local iconName = product.Icon
					or (if ShopIcons.Get(product.Id) ~= nil then product.Id else visual.Icon)
				productCard(
					grid,
					index,
					product.DisplayName,
					product.Description,
					iconName,
					visual.Accent,
					actionText,
					enabled,
					function()
						local bought, message = Net.Function("PromptProduct"):InvokeServer(product.Id)
						if not bought then
							toast(message)
						end
					end,
					if sellable then nil else priceText
				)
			end
		end)
	end
end

function MenuController:_renderTitles(parent: Frame)
	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
	local selectedId = if data ~= nil then data.SelectedTitleId else "Newbie"

	local intro = UI.Label("Intro", parent)
	intro.Size = UDim2.new(1, 0, 0, 38)
	intro.LayoutOrder = 1
	intro.TextSize = 13
	intro.TextWrapped = true
	intro.TextColor3 = UI.Palette.TextMuted
	intro.Text =
		"Power unlocks titles permanently, and the VIP pass unlocks its own. Select any unlocked title to display it above your player."

	-- The pass the title needs, answered from the attribute its grant sets. The server
	-- checks ownership itself before equipping anything; this only decides what the row
	-- draws, so a stale attribute costs a redraw rather than a free title.
	local function ownsGamepass(productId: string): boolean
		return Players.LocalPlayer:GetAttribute(`{productId}Owned`) == true
	end

	for index, rank in RankConfig.List do
		local unlocked = RankConfig.IsUnlocked(rank.Id, power, ownsGamepass)
		local selected = selectedId == rank.Id
		local pass = rank.RequiresGamepass
		local line = row(parent, 64, index + 1)
		line.BackgroundColor3 = if selected
			then rank.Color:Lerp(UI.Palette.Backdrop, 0.68)
			else UI.Palette.Backdrop

		local name = UI.Label("Name", line)
		name.Position = UDim2.fromOffset(4, 6)
		name.Size = UDim2.new(0.45, 0, 0, 24)
		name.Font = UI.Font.Heading
		name.TextSize = 17
		name.TextColor3 = rank.Color
		name.Text = string.upper(rank.DisplayName)

		local requirement = UI.Label("Requirement", line)
		requirement.Position = UDim2.fromOffset(4, 32)
		requirement.Size = UDim2.new(0.62, 0, 0, 19)
		requirement.TextSize = 12
		requirement.TextColor3 = UI.Palette.TextMuted
		requirement.Text = if pass ~= nil
			then (if unlocked
				then "GAMEPASS · UNLOCKED"
				else `REQUIRES THE {string.upper(rank.DisplayName)} GAMEPASS`)
			elseif unlocked then `{NumberFormat.Format(rank.MinPower)} POWER · UNLOCKED`
			else `NEED {NumberFormat.Format(rank.MinPower - power)} MORE POWER`

		local choose = Instance.new("TextButton")
		choose.AnchorPoint = Vector2.new(1, 0.5)
		choose.Position = UDim2.new(1, -8, 0.5, 0)
		choose.Size = UDim2.fromOffset(150, 40)
		choose.BackgroundColor3 = if selected
			then UI.Palette.Vital
			elseif unlocked then rank.Color
			else UI.Palette.Glass
		choose.BackgroundTransparency = if unlocked then 0 else 0.5
		choose.BorderSizePixel = 0
		choose.Font = UI.Font.Heading
		choose.TextSize = 12
		choose.TextColor3 = if unlocked then UI.Palette.OnAccent else UI.Palette.TextMuted
		-- A locked power rank is a matter of training; a locked pass is a matter of
		-- buying, and the shop is one prompt away, so that row stays pressable.
		choose.Text = if selected
			then "EQUIPPED"
			elseif unlocked then "SELECT TITLE"
			elseif pass ~= nil then `GET {string.upper(rank.DisplayName)}`
			else "LOCKED"
		choose.Active = not selected and (unlocked or pass ~= nil)
		choose.Parent = line
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = choose
		if choose.Active then
			UI.Pressable(choose)
			choose.Activated:Connect(function()
				if not unlocked and pass ~= nil then
					local bought, message = Net.Function("PromptProduct"):InvokeServer(pass)
					if not bought then
						toast(message)
					end
					return
				end
				local ok, message = Net.Function("SelectTitle"):InvokeServer(rank.Id)
				toast(message)
				if ok then
					self:_refresh()
				end
			end)
		end
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
	local data = ProfileController:Get()
	local settings = if data ~= nil
		then data.Settings
		else { MasterVolume = 100, MusicVolume = 70, SfxVolume = 100 }
	local order = 0

	--[[
		A volume row. The mix follows the handle live and only the release is sent.

		Two separate reasons, both learned the hard way elsewhere in this file: `Net` rate
		limits the settings remote to four calls, so a per-frame invoke during a drag
		would spend a player's whole budget and start failing mid-slide; and `_refresh`
		rebuilds this whole page, which would destroy the slider under the finger still
		dragging it. So the drag writes straight to SoundBus and nothing is redrawn until
		the player lets go.
	]]
	local function volumeRow(settingName: string, displayName: string, detail: string, colour: Color3)
		order += 1
		local line = row(parent, 64, order)

		local label = UI.Label("Text", line)
		label.Size = UDim2.fromScale(0.46, 1)
		label.TextSize = 14
		label.Text = `<b>{displayName}</b>\n<font color="#8A93A8">{detail}</font>`

		local current = (settings :: any)[settingName]
		local slider = UI.Slider(settingName, line, {
			Value = if type(current) == "number" then current else 100,
			Colour = colour,
			OnChanged = function(value: number)
				local live = ProfileController:Get()
				if live ~= nil then
					(live.Settings :: any)[settingName] = value
					Loader.Get("EffectsController"):_applyVolumes()
				end
			end,
			OnCommitted = function(value: number)
				local ok, message = Net.Function("UpdateSetting"):InvokeServer(settingName, value)
				if not ok then
					toast(message)
				end
			end,
		})
		slider.Root.Size = UDim2.new(0.5, -12, 0, 22)
		slider.Root.Position = UDim2.new(0.5, 12, 0.5, -11)
	end

	order += 1
	local appearance = row(parent, 58, order)
	local appearanceLabel = UI.Label("Text", appearance)
	appearanceLabel.Size = UDim2.new(1, -132, 1, 0)
	appearanceLabel.TextSize = 14
	appearanceLabel.Text = `<b>Appearance</b>\n<font color="#8A93A8">Skin, shorts, hair and face</font>`

	-- The creator needs the whole screen to show the body it is changing, so the menu
	-- gets out of the way rather than hosting it as a page.
	button(appearance, "EDIT", UI.Palette.Accent, function()
		-- Open closes this menu itself, the same way the full map does. Closing it
		-- here as well worked only because Toggle happens to be synchronous.
		Loader.Get("CustomizerController"):Open(false)
	end)

	volumeRow("MasterVolume", "Master", "Everything the game plays", UI.Palette.Accent)
	volumeRow("MusicVolume", "Music", "Soundtrack and world ambience", UI.Palette.Token)
	volumeRow("SfxVolume", "Sound effects", "Training, combat, and menu feedback", UI.Palette.Power)

	order += 1
	local claim = row(parent, 58, order)
	local label = UI.Label("Text", claim)
	label.Size = UDim2.new(1, -132, 1, 0)

	--[[
		The daily resets on the UTC calendar day, which is what VipService.today()
		means by "once a day". So the wait is the rest of today in UTC — not a rolling
		twenty-four hours from the claim, which would be a different promise and a
		longer one.

		Derived here rather than asked for: VipLastClaimDay is on the profile and
		already reaches this client with every push, so a countdown costs no traffic.
	]]
	local claimData = ProfileController:Get()
	local claimedToday = claimData ~= nil and claimData.VipLastClaimDay == os.date("!%Y-%m-%d")

	local function secondsUntilReset(): number
		return 86400 - (os.time() % 86400)
	end

	label.Text = if claimedToday
		then `<b>VIP daily protection</b>\n<font color="#8A93A8">Claimed today. The next hour is waiting tomorrow.</font>`
		else `<b>VIP daily protection</b>\n<font color="#8A93A8">Claim one hour of immortality every day</font>`

	local claimButton = button(
		claim,
		if claimedToday then `READY IN {NumberFormat.Duration(secondsUntilReset())}` else "CLAIM",
		if claimedToday then UI.Palette.Glass else UI.Palette.Token,
		function()
			local ok, message = Net.Function("ClaimVipDaily"):InvokeServer()
			toast(message)
			-- Re-rendered on success so the button becomes its own countdown rather
			-- than inviting a second press the server would refuse.
			if ok then
				self:_refresh()
			end
		end
	)

	if claimedToday then
		claimButton.Active = false
		claimButton.AutoButtonColor = false
		claimButton.TextColor3 = UI.Palette.TextMuted
		claimButton.TextSize = 12
		-- Dies with the page. Settings is rebuilt on every open and on every refresh,
		-- so without this guard each visit would leave another loop writing to a
		-- button nobody can see.
		task.spawn(function()
			-- IsDescendantOf rather than a Parent check: a rebuilt page destroys the
			-- old row, and a destroyed instance still reports whatever parent it had.
			while claimButton:IsDescendantOf(game) do
				task.wait(1)
				if not claimButton:IsDescendantOf(game) then
					break
				end
				local left = secondsUntilReset()
				if left <= 0 then
					self:_refresh()
					break
				end
				claimButton.Text = `READY IN {NumberFormat.Duration(left)}`
			end
		end)
	end

	order += 1
	local heading = UI.Label("ControlsHeading", parent)
	heading.Size = UDim2.new(1, 0, 0, 28)
	heading.LayoutOrder = order
	heading.Font = UI.Font.Heading
	heading.TextSize = 14
	heading.TextColor3 = UI.Palette.Accent
	heading.Text = "CONTROLS"

	order += 1
	local note = row(parent, 112, order)
	local noteText = UI.Label("Note", note)
	noteText.Size = UDim2.fromScale(1, 1)
	noteText.TextSize = 13
	noteText.TextWrapped = true
	noteText.TextColor3 = UI.Palette.TextMuted
	noteText.Text = "Hold E at a machine to mount or dismount  ·  Space dismounts\n"
		.. "Hold mouse to train the selected hotbar muscle  ·  F punches\n"
		.. "Shift sprints  ·  Q flies  ·  Space climbs  ·  Ctrl descends\n"
		.. "M opens the menu  ·  Tab toggles the player list"
end

function MenuController:_refresh()
	if not isOpen then
		return
	end

	for tabId, tabButton in tabButtons do
		local selected = tabId == activeTab
		tabButton.BackgroundColor3 = if selected then UI.Palette.Accent else UI.Palette.Backdrop
		tabButton.BackgroundTransparency = if selected then 0 else 0.2
		tabButton.TextColor3 = if selected then UI.Palette.OnAccent else UI.Palette.TextMuted
		local stroke = tabButton:FindFirstChildOfClass("UIStroke")
		if stroke ~= nil then
			stroke.Transparency = if selected then 0.05 else 0.75
			stroke.Color = if selected then UI.Palette.Accent else UI.Palette.GlassStroke
		end
	end

	-- Info, Shop and Settings form the menu. Quests and Ranks are standalone HUD
	-- destinations, so showing the menu strip above them falsely implies a hierarchy
	-- they do not belong to and wastes a full row of usable space.
	local hasMenuTabs = activeTab == "Info"
		or activeTab == "Muscles"
		or activeTab == "Shop"
		or activeTab == "Settings"
	tabStrip.Visible = hasMenuTabs
	-- The standalone pages are full width, so they pass under the close button rather
	-- than stopping short of it the way the tab strip does. They start below the header
	-- band instead, or the first card's corner sits under the button.
	local band = if hasMenuTabs then TABBED_BAND else HEADER_BAND
	bodyScroll.Position = UDim2.fromOffset(0, band)
	bodyScroll.Size = UDim2.new(1, 0, 1, -band)

	local fixedPage = activeTab == "Info"
	bodyScroll.ScrollingEnabled = not fixedPage
	bodyScroll.ScrollBarThickness = if fixedPage then 0 else 4
	bodyScroll.AutomaticCanvasSize = if fixedPage then Enum.AutomaticSize.None else Enum.AutomaticSize.Y
	bodyScroll.CanvasPosition = Vector2.zero

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
end

--[[
	Toggles the menu. With a tab id, toggles *that* screen: opens on it, or closes
	if it is already the one showing — which is what a button in a bar has to do,
	because pressing it twice should put you back where you were.
]]
function MenuController:Toggle(tabId: string?)
	local FullMapController = Loader.Get("FullMapController")
	if FullMapController:IsOpen() then
		FullMapController:Close()
	end

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
	local FullMapController = Loader.Get("FullMapController")
	if FullMapController:IsOpen() then
		FullMapController:Close()
	end

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
	trainPollToken += 1
end

function MenuController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymMenu"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 5
	screen.Enabled = false
	screen.Parent = playerGui
	UI.ScaleWithViewport(screen)

	local panel = UI.Panel("Menu", screen)
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(720, 510)
	panel.BackgroundTransparency = 0.02

	local panelAspect = Instance.new("UIAspectRatioConstraint")
	panelAspect.AspectRatio = 720 / 510
	panelAspect.Parent = panel

	titleLabel = UI.Label("Title", panel)
	titleLabel.Size = UDim2.new(1, -42, 0, 22)
	titleLabel.Font = UI.Font.Heading
	titleLabel.TextSize = 13
	titleLabel.TextColor3 = UI.Palette.TextMuted
	titleLabel.Text = "GYM NETWORK"

	-- No OnPress: nothing else on this page makes a sound, and one control that clicks
	-- while its neighbours are silent reads as a bug rather than as polish.
	local close = Icons.CloseButton(panel, {
		Size = CLOSE_SIZE,
		OnActivated = function()
			self:Toggle()
		end,
	})
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(1, 0)

	-- The user's three top-level menu pages live together here. Direct HUD routes such
	-- as Quests hide this strip in _refresh, so they read as their own surfaces.
	tabStrip = Instance.new("Frame")
	tabStrip.Name = "Tabs"
	tabStrip.BackgroundTransparency = 1
	tabStrip.Position = UDim2.fromOffset(0, 28)
	tabStrip.Size = UDim2.new(1, -38, 0, 44)
	tabStrip.Parent = panel

	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabStrip

	local menuTabIds = { "Info", "Muscles", "Shop", "Settings" }
	for index, tabId in menuTabIds do
		local tabButton = Instance.new("TextButton")
		tabButton.Name = tabId
		tabButton.LayoutOrder = index
		tabButton.Size = UDim2.new(1 / #menuTabIds, -6, 1, 0)
		tabButton.BackgroundColor3 = UI.Palette.Backdrop
		tabButton.BackgroundTransparency = 0.2
		tabButton.BorderSizePixel = 0
		tabButton.AutoButtonColor = false
		tabButton.Font = UI.Font.Heading
		tabButton.TextSize = 15
		tabButton.TextColor3 = UI.Palette.TextMuted
		tabButton.Text = string.upper(tabId)
		tabButton.Parent = tabStrip

		local tabCorner = Instance.new("UICorner")
		tabCorner.CornerRadius = UDim.new(0, 8)
		tabCorner.Parent = tabButton

		local tabStroke = Instance.new("UIStroke")
		tabStroke.Color = UI.Palette.GlassStroke
		tabStroke.Transparency = 0.75
		tabStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		tabStroke.Parent = tabButton

		UI.Pressable(tabButton, { PressScale = 0.97, HoverScale = 1.01 })
		tabButton.Activated:Connect(function()
			self:Open(tabId)
		end)
		tabButtons[tabId] = tabButton
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, TABBED_BAND)
	scroll.Size = UDim2.new(1, 0, 1, -TABBED_BAND)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollBarThickness = 4
	scroll.Parent = panel

	bodyScroll = scroll
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
		if
			isOpen
			and (
				activeTab == "Info"
				or activeTab == "Muscles"
				or activeTab == "Titles"
				or activeTab == "Shop"
				or activeTab == "Settings"
			)
		then
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
