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
}

-- All 55 training locations come from the server because StreamingEnabled means
-- most physical stations do not exist in the spawn client's Workspace yet.
local destinations: { Destination } = {}
local destinationsById: { [string]: Destination } = {}
local selectedDestination: string? = nil

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
	if #destinations > 0 then
		return
	end

	local ok, list = pcall(function()
		return Net.Function("GetDestinations"):InvokeServer()
	end)
	if not ok or type(list) ~= "table" then
		return
	end

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
		}
		table.insert(destinations, destination)
		destinationsById[destination.Id] = destination
	end
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

	if #destinations == 0 then
		local empty = UI.Label("Empty", board)
		empty.Size = UDim2.fromScale(1, 1)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		empty.TextColor3 = UI.Palette.TextMuted
		empty.Text = "The map is still loading."
		return
	end

	local minX, maxX, minZ, maxZ = 0, 0, 0, 0
	for _, destination in destinations do
		local at = destination.Position
		minX, maxX = math.min(minX, at.X), math.max(maxX, at.X)
		minZ, maxZ = math.min(minZ, at.Z), math.max(maxZ, at.Z)
	end
	local padX = math.max((maxX - minX) * 0.08, 1)
	local padZ = math.max((maxZ - minZ) * 0.08, 1)
	minX, maxX, minZ, maxZ = minX - padX, maxX + padX, minZ - padZ, maxZ + padZ

	local function project(x: number, z: number): UDim2
		-- World +Z is north, and screen Y grows downward, so Z is flipped.
		return UDim2.fromScale((x - minX) / (maxX - minX), 1 - (z - minZ) / (maxZ - minZ))
	end

	local hub = UI.Label("Hub", board)
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = project(0, 0)
	hub.Size = UDim2.fromOffset(90, 16)
	hub.TextXAlignment = Enum.TextXAlignment.Center
	hub.TextSize = 11
	hub.TextColor3 = UI.Palette.TextMuted
	hub.Text = "SPAWN"

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
		local size = if isSelected then 22 else 15
		local at = destination.Position

		local pin = Instance.new("TextButton")
		pin.Name = destination.Id
		pin.AnchorPoint = Vector2.new(0.5, 0.5)
		pin.Position = project(at.X, at.Z)
		pin.Size = UDim2.fromOffset(size, size)
		pin.BackgroundColor3 = stat.Color
		pin.BackgroundTransparency = if unlocked then 0 else 0.68
		pin.BorderSizePixel = 0
		pin.Font = UI.Font.Numeric
		pin.TextSize = 9
		pin.TextColor3 = UI.Palette.Backdrop
		pin.Text = string.sub(stat.DisplayName, 1, 1)
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
	tagline.Text = `{zone.DisplayName} location  ·  {zone.Tagline}`

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

	button(action, "Travel", stat.Color, function()
		local ok, message = Net.Function("Travel"):InvokeServer(destination.Id)
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

		local line = row(parent, 56, index)

		local label = UI.Label("Text", line)
		label.Size = UDim2.new(1, -120, 0, 26)
		label.Position = UDim2.fromOffset(0, 6)
		label.TextColor3 = definition.Color
		label.Text = `{definition.DisplayName}  <font color="#8A93A8">lvl {level} · </font>`
			.. `x{string.format("%.2f", Formulas.MultiplierValue(level))}`

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
		self:_refresh()
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
	self:_refresh()
	self:_publish()
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
