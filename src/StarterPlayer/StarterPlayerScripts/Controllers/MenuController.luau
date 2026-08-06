--!strict
--[[
	MenuController — the tabbed menu: upgrades, quests, shop, leaderboard, settings.

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
local activeTab = "Upgrades"
local quests: { any } = {}

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
	panel.Size = UDim2.fromOffset(560, 430)
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
		if isOpen and (activeTab == "Upgrades" or activeTab == "Shop") then
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
