--!strict
--[[
	MenuBarController — the buttons down the right of the screen.

	Everything the menu holds used to be behind either the M key or a walk back to
	the plaza to talk to somebody. Neither is discoverable: a player who never
	presses M never learns the game has upgrades, and one who is out on Storm Peak
	cannot reach the shop without travelling home first. So the screens that are not
	*about* a place get a permanent button.

	Quests deliberately does not. Coach standing in the plaza is how you are meant
	to find those, and a button beside the others would make him scenery. Which tabs
	appear here is `OnBar` on the tab itself, defaulting to true — the bar never
	names a screen, so adding one to MenuController puts it here automatically.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)

local BUTTON_WIDTH = 132
local BUTTON_HEIGHT = 38
local SPACING = 6

local MenuBarController = {
	Name = "MenuBarController",
	Priority = 8,
}

local MenuController: any = nil

function MenuBarController:Init()
	MenuController = Loader.Get("MenuController")
end

function MenuBarController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Read the tabs in Start rather than Init: MenuController fills its own table
	-- in Init, and all Inits finish before any Start does.
	local entries = MenuController:GetBarTabs()

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymMenuBar"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	-- Below the menu itself, so an open panel is never covered by its own buttons.
	screen.DisplayOrder = 4
	screen.Parent = playerGui

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(1, 0.5)
	bar.Position = UDim2.new(1, -16, 0.5, 0)
	bar.Size = UDim2.fromOffset(BUTTON_WIDTH, #entries * BUTTON_HEIGHT + math.max(0, #entries - 1) * SPACING)
	bar.Parent = screen

	local layout = UI.VerticalList(bar, SPACING)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right

	for index, entry in entries do
		local btn = Instance.new("TextButton")
		btn.Name = entry.Id
		btn.LayoutOrder = index
		btn.Size = UDim2.fromOffset(BUTTON_WIDTH, BUTTON_HEIGHT)
		btn.BackgroundColor3 = UI.Palette.Glass
		btn.BackgroundTransparency = 0.2
		btn.BorderSizePixel = 0
		btn.AutoButtonColor = true
		btn.Font = UI.Font.Heading
		btn.TextSize = 15
		btn.TextColor3 = UI.Palette.Text
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.Text = string.upper(entry.DisplayName)
		btn.Parent = bar

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = btn

		local stroke = Instance.new("UIStroke")
		stroke.Color = UI.Palette.GlassStroke
		stroke.Transparency = 0.7
		stroke.Parent = btn

		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 16)
		padding.Parent = btn

		-- The accent bar on the leading edge, which is what stops five identical
		-- dark rectangles reading as one block.
		local tick = Instance.new("Frame")
		tick.Name = "Tick"
		tick.AnchorPoint = Vector2.new(0, 0.5)
		tick.Position = UDim2.new(0, -10, 0.5, 0)
		tick.Size = UDim2.fromOffset(4, BUTTON_HEIGHT - 14)
		tick.BackgroundColor3 = UI.Palette.Accent
		tick.BorderSizePixel = 0
		tick.Parent = btn

		local tickCorner = Instance.new("UICorner")
		tickCorner.CornerRadius = UDim.new(1, 0)
		tickCorner.Parent = tick

		btn.Activated:Connect(function()
			-- Toggling on the id means a second press closes it again, which is
			-- what a button that is always on screen has to do.
			MenuController:Toggle(entry.Id)
		end)
	end
end

function MenuBarController:Start()
	self:_build()
end

return MenuBarController
