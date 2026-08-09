--!strict
--[[
	MenuBarController — the one persistent MENU button from the HUD sketch.

	Info, Shop, and Settings are tabs inside MenuController. This control is only the
	door: bottom-right on desktop, lifted above Roblox's jump controls on touch.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)

local MenuBarController = {
	Name = "MenuBarController",
	Priority = 8,
}

local MenuController: any = nil
local EffectsController: any = nil
local menuButton: TextButton
local iconTile: Frame
local iconBars: { Frame } = {}
local buttonStroke: UIStroke

function MenuBarController:Init()
	MenuController = Loader.Get("MenuController")
	EffectsController = Loader.Get("EffectsController")
end

local function paint(open: boolean)
	menuButton.BackgroundColor3 = if open then UI.Palette.Accent else UI.Palette.Glass
	menuButton.BackgroundTransparency = if open then 0.02 else 0.08
	menuButton.TextColor3 = if open then UI.Palette.Backdrop else UI.Palette.Text
	iconTile.BackgroundColor3 = if open then UI.Palette.Backdrop else UI.Palette.Accent
	buttonStroke.Color = if open then UI.Palette.Accent else UI.Palette.GlassStroke
	buttonStroke.Transparency = if open then 0.05 else 0.45

	for _, bar in iconBars do
		bar.BackgroundColor3 = if open then UI.Palette.Accent else UI.Palette.Backdrop
	end
end

function MenuBarController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymMenuButton"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 4
	screen.Parent = playerGui
	UI.ScaleWithViewport(screen)

	menuButton = Instance.new("TextButton")
	menuButton.Name = "Menu"
	menuButton.AnchorPoint = Vector2.new(1, 1)
	menuButton.Position = if UserInputService.TouchEnabled
		then UDim2.new(1, -18, 1, -146)
		else UDim2.new(1, -18, 1, -18)
	menuButton.Size = UDim2.fromOffset(132, 54)
	menuButton.BackgroundColor3 = UI.Palette.Glass
	menuButton.BackgroundTransparency = 0.08
	menuButton.BorderSizePixel = 0
	menuButton.AutoButtonColor = false
	menuButton.Font = UI.Font.Heading
	menuButton.TextSize = 17
	menuButton.TextColor3 = UI.Palette.Text
	menuButton.TextXAlignment = Enum.TextXAlignment.Right
	menuButton.Text = "MENU   "
	menuButton.Parent = screen

	local buttonCorner = Instance.new("UICorner")
	buttonCorner.CornerRadius = UDim.new(0, 9)
	buttonCorner.Parent = menuButton

	buttonStroke = Instance.new("UIStroke")
	buttonStroke.Color = UI.Palette.GlassStroke
	buttonStroke.Thickness = 2
	buttonStroke.Transparency = 0.45
	buttonStroke.Parent = menuButton

	iconTile = Instance.new("Frame")
	iconTile.Name = "Icon"
	iconTile.AnchorPoint = Vector2.new(0, 0.5)
	iconTile.Position = UDim2.new(0, 7, 0.5, 0)
	iconTile.Size = UDim2.fromOffset(40, 40)
	iconTile.BackgroundColor3 = UI.Palette.Accent
	iconTile.BorderSizePixel = 0
	iconTile.Parent = menuButton

	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = iconTile

	local iconCorner = Instance.new("UICorner")
	iconCorner.CornerRadius = UDim.new(0, 7)
	iconCorner.Parent = iconTile

	for index, width in { 22, 17, 22 } do
		local bar = Instance.new("Frame")
		bar.Name = `Bar{index}`
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Position = UDim2.fromOffset(20, 12 + (index - 1) * 8)
		bar.Size = UDim2.fromOffset(width, 3)
		bar.BackgroundColor3 = UI.Palette.Backdrop
		bar.BorderSizePixel = 0
		bar.Parent = iconTile

		local barCorner = Instance.new("UICorner")
		barCorner.CornerRadius = UDim.new(1, 0)
		barCorner.Parent = bar
		table.insert(iconBars, bar)
	end

	UI.Pressable(menuButton, {
		PressScale = 0.95,
		HoverScale = 1.02,
		OnPress = function()
			EffectsController:Play("UiClick")
		end,
	})

	menuButton.Activated:Connect(function()
		if MenuController:GetOpenTab() ~= nil then
			MenuController:Toggle()
		else
			MenuController:Open("Info")
		end
	end)
end

function MenuBarController:Start()
	self:_build()
	paint(MenuController:GetOpenTab() ~= nil)

	MenuController.Changed:Connect(function(openTab: string?)
		paint(openTab ~= nil)
	end)
end

return MenuBarController
