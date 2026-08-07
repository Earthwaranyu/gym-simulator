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

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local ShopConfig = require(ReplicatedStorage.Modules.ShopConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local MenuController = {
	Name = "MenuController",
	Priority = 7,
}

local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local body: Frame
local titleLabel: TextLabel
local tabStrip: Frame
local isOpen = false
local activeTab = "Map"
local quests: { any } = {}

-- District id -> where its landing pad is in the world. Fetched once from the
-- server, because StreamingEnabled means the client cannot see a pad 1,500 studs
-- away to measure it. Pads do not move, so one fetch is enough.
local destinations: { [string]: Vector3? } = {}
local selectedZone: string? = nil

type Tab = {
	Id: string,
	DisplayName: string,
	Render: (parent: Frame) -> (),
}

local tabs: { Tab } = {}

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
			Id = "Upgrades",
			DisplayName = "Upgrades",
			Render = function(parent)
				self:_renderUpgrades(parent)
			end,
		},
		{
			Id = "Quests",
			DisplayName = "Quests",
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

--[[
	Pulls every district's landing pad from the server, once.
]]
function MenuController:_fetchDestinations()
	if next(destinations) ~= nil then
		return
	end

	local ok, list = pcall(function()
		return Net.Function("GetDestinations"):InvokeServer()
	end)
	if not ok or type(list) ~= "table" then
		return
	end

	for _, entry in list do
		if type(entry) == "table" and type(entry.Id) == "string" then
			destinations[entry.Id] = Vector3.new(entry.X, entry.Y, entry.Z)
		end
	end
end

--[[
	The travel map: every district as a pin on a plan view, and a panel for
	whichever one is selected.

	Pins carry a tier number rather than a name. Eleven labels on a board this
	size overlap in the middle, where Downtown's two gyms sit almost on top of
	each other, and an unreadable map is worse than a list. The board is stretched
	to fit rather than kept to scale for the same reason — it is a diagram of where
	things are relative to each other, not a survey.
]]
function MenuController:_renderMap(parent: Frame)
	self:_fetchDestinations()

	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0

	-- Default to the furthest district already open: that is where somebody
	-- opening this menu almost always means to go.
	if selectedZone == nil then
		for _, zone in ZoneConfig.List do
			if power >= zone.RequiredPower then
				selectedZone = zone.Id
			end
		end
	end

	local board = Instance.new("Frame")
	board.Name = "Board"
	board.BackgroundColor3 = UI.Palette.Backdrop
	board.BackgroundTransparency = 0.2
	board.BorderSizePixel = 0
	board.Size = UDim2.new(1, 0, 0, 258)
	board.LayoutOrder = 1
	board.Parent = parent

	local boardCorner = Instance.new("UICorner")
	boardCorner.CornerRadius = UDim.new(0, 8)
	boardCorner.Parent = board

	local boardStroke = Instance.new("UIStroke")
	boardStroke.Color = UI.Palette.GlassStroke
	boardStroke.Transparency = 0.75
	boardStroke.Parent = board

	if next(destinations) == nil then
		local empty = UI.Label("Empty", board)
		empty.Size = UDim2.fromScale(1, 1)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "The map is still loading."
		return
	end

	-- Bounds seeded with the origin so Downtown anchors the middle even before
	-- any outer district has been reached.
	local minX, maxX, minZ, maxZ = 0, 0, 0, 0
	for _, at in destinations do
		if at ~= nil then
			minX, maxX = math.min(minX, at.X), math.max(maxX, at.X)
			minZ, maxZ = math.min(minZ, at.Z), math.max(maxZ, at.Z)
		end
	end
	local padX = math.max((maxX - minX) * 0.08, 1)
	local padZ = math.max((maxZ - minZ) * 0.08, 1)
	minX, maxX, minZ, maxZ = minX - padX, maxX + padX, minZ - padZ, maxZ + padZ

	local function project(x: number, z: number): UDim2
		-- World +Z is north, and screen Y grows downward, so Z is flipped.
		return UDim2.fromScale((x - minX) / (maxX - minX), 1 - (z - minZ) / (maxZ - minZ))
	end

	-- Downtown itself has no district entry — it is the hub, not a tier — but it
	-- is the thing every other pin is placed relative to, so it gets a marker.
	local hub = UI.Label("Hub", board)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(90, 16)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.TextSize = 11
	hub.TextColor3 = UI.Palette.TextMuted
	hub.Text = "DOWNTOWN"

	local unlockedCount = 0
	for index, zone in ZoneConfig.List do
		local at = destinations[zone.Id]
		if at == nil then
			continue
		end

		local unlocked = power >= zone.RequiredPower
		if unlocked then
			unlockedCount += 1
		end
		local isSelected = selectedZone == zone.Id
		local size = if isSelected then 26 else 20

		local pin = Instance.new("TextButton")
		pin.Name = zone.Id
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = project(at.X, at.Z)
		pin.Size = UDim2.fromOffset(size, size)
		pin.BackgroundColor3 = zone.Color
		pin.BackgroundTransparency = if unlocked then 0 else 0.6
		pin.BorderSizePixel = 0
		pin.Font = UI.Font.Numeric
		pin.TextSize = 12
		pin.TextColor3 = UI.Palette.Backdrop
		pin.Text = tostring(index)
		pin.ZIndex = if isSelected then 3 else 2
		pin.Parent = board

		local pinCorner = Instance.new("UICorner")
		pinCorner.CornerRadius = UDim.new(1, 0)
		pinCorner.Parent = pin

		local pinStroke = Instance.new("UIStroke")
		pinStroke.Color = if isSelected then UI.Palette.Text else UI.Palette.Backdrop
		pinStroke.Thickness = if isSelected then 2 else 1
		pinStroke.Parent = pin

		pin.Activated:Connect(function()
			selectedZone = zone.Id
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
		here.ZIndex = 4
		here.Parent = board

		local hereCorner = Instance.new("UICorner")
		hereCorner.CornerRadius = UDim.new(1, 0)
		hereCorner.Parent = here
	end

	local count = UI.Label("Count", parent)
	count.Size = UDim2.new(1, 0, 0, 20)
	count.LayoutOrder = 2
	count.TextSize = 12
	count.TextColor3 = UI.Palette.TextMuted
	count.Text = `{unlockedCount} of {#ZoneConfig.List} districts open  ·  travel is free from the plaza`

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

--[[
	The panel under the map: what the selected district is, and the button.
]]
function MenuController:_renderDestination(parent: Frame, power: number)
	local zone = if selectedZone ~= nil then ZoneConfig.Get(selectedZone) else nil
	if zone == nil then
		return
	end

	local heading = UI.Label("Name", parent)
	heading.Size = UDim2.new(1, 0, 0, 24)
	heading.LayoutOrder = 3
	heading.Font = UI.Font.Heading
	heading.TextSize = 17
	heading.TextColor3 = zone.Color
	heading.Text = string.upper(zone.DisplayName)

	local tagline = UI.Label("Tagline", parent)
	tagline.Size = UDim2.new(1, 0, 0, 18)
	tagline.LayoutOrder = 4
	tagline.TextSize = 13
	tagline.TextColor3 = UI.Palette.TextMuted
	tagline.Text = zone.Tagline

	local action = row(parent, 44, 5)
	local detail = UI.Label("Detail", action)
	detail.Size = UDim2.new(1, -120, 1, 0)
	detail.TextSize = 13

	local shortfall = zone.RequiredPower - power
	if shortfall > 0 then
		detail.Text = `<font color="#FF5C5C">Needs {NumberFormat.Format(shortfall)} more power</font>`
			.. `  ·  x{NumberFormat.Format(zone.GainMultiplier)} gains`
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

	detail.Text = `x{NumberFormat.Format(zone.GainMultiplier)} gains  ·  `
		.. `<font color="#7EE7FF">open</font>`

	button(action, "Travel", zone.Color, function()
		local ok, message = Net.Function("Travel"):InvokeServer(zone.Id)
		toast(message)
		if ok then
			self:Toggle()
		end
	end)
end

function MenuController:_renderUpgrades(parent: Frame)
	local data = ProfileController:Get()

	for index, definition in StatConfig.List do
		local level = if data ~= nil then (data.MultiplierLevels[definition.Id] or 0) else 0
		local cost = Formulas.MultiplierCost(level)

		local line = row(parent, 44, index)

		local label = UI.Label("Text", line)
		label.Size = UDim2.new(1, -120, 1, 0)
		label.TextColor3 = definition.Color
		label.Text = `{definition.DisplayName}  <font color="#8A93A8">lvl {level} · </font>`
			.. `x{string.format("%.2f", Formulas.MultiplierValue(level))}`

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
	note.Size = UDim2.new(1, 0, 0, 60)
	note.LayoutOrder = 2
	note.TextSize = 13
	note.TextWrapped = true
	note.TextColor3 = UI.Palette.TextMuted
	note.Text = "Walk up to any machine to train automatically.\n"
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
			self:_refresh()
		end)
	end
end

function MenuController:Toggle()
	isOpen = not isOpen
	screen.Enabled = isOpen
	if isOpen then
		self:_refresh()
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
