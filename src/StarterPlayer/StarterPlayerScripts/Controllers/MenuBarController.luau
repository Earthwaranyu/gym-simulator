--!strict
--[[
	MenuBarController — the buttons down the left of the screen.

	Everything the menu holds used to be behind either the M key or a walk back to
	the plaza to talk to somebody. Neither is discoverable: a player who never
	presses M never learns the game has upgrades, and one out on Storm Peak cannot
	reach the shop without travelling home first.

	Quests deliberately has no button. Coach standing in the plaza is how you are
	meant to find those, and a button beside the others would make him scenery.
	Which tabs appear is `OnBar` on the tab itself, defaulting to true, so the bar
	never names a screen and a new tab arrives with a button already.

	Three things about the shape of it, all of which the first version got wrong:

	  * **Left, not right.** On a phone the right half of the screen is where you
	    drag to turn the camera. Buttons there compete with looking around, and it
	    is not where anyone looks for navigation either.
	  * **A real touch target.** Tiles are sized from TILE, which is above the
	    ~48px floor for a finger and separated by SPACING so neighbours are not
	    mis-tapped. The old bar was 38px tall on every device.
	  * **Icon first.** Five dark rectangles of text read as more HUD panels. A
	    glyph is what makes a button look like a button, and it is what a player of
	    this genre is scanning for.

	The bar keeps clear of the two corners Roblox owns on touch — the thumbstick at
	bottom-left and the jump button at bottom-right — by sitting on the vertical
	centre, and clear of Roblox's own menu by staying off the top-right.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local Icons = require(ReplicatedStorage.Modules.Icons)

-- Square side of the icon tile, and therefore the height of the whole button.
local TILE = 56
-- Room for the label beside the tile.
local LABEL_WIDTH = 108
-- Gap between buttons. Enough that a thumb cannot catch two at once.
local SPACING = 8
local EDGE_MARGIN = 16

local MenuBarController = {
	Name = "MenuBarController",
	Priority = 8,
}

local MenuController: any = nil
local EffectsController: any = nil

type Entry = {
	Id: string,
	Button: TextButton,
	Tile: Frame,
	Label: TextLabel,
	Glyph: Frame,
	Stroke: UIStroke,
}

local entries: { Entry } = {}

function MenuBarController:Init()
	MenuController = Loader.Get("MenuController")
	EffectsController = Loader.Get("EffectsController")
end

--[[
	Paints one button for the state it is in. Resting is a dark tile with an accent
	glyph; open is the accent filled in and the glyph knocked out of it, which is
	the strongest signal available without introducing a second colour.
]]
local function paint(entry: Entry, open: boolean)
	local tileColor = if open then UI.Palette.Accent else UI.Palette.Backdrop
	local glyphColor = if open then UI.Palette.Backdrop else UI.Palette.Accent

	entry.Tile.BackgroundColor3 = tileColor
	entry.Button.BackgroundTransparency = if open then 0.05 else 0.25
	entry.Label.TextColor3 = if open then UI.Palette.Text else UI.Palette.TextMuted
	entry.Stroke.Transparency = if open then 0.35 else 0.75
	Icons.Recolour(entry.Glyph, glyphColor, tileColor)
end

function MenuBarController:_refresh(openTab: string?)
	for _, entry in entries do
		paint(entry, entry.Id == openTab)
	end
end

function MenuBarController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- Read the tabs in Start rather than Init: MenuController fills its own table
	-- in Init, and every Init finishes before any Start begins.
	local tabs = MenuController:GetBarTabs()

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymMenuBar"
	screen.ResetOnSpawn = false
	-- Matches the HUD, so both live in the same coordinate space and "vertically
	-- centred" means centred in the area the player can actually see.
	screen.IgnoreGuiInset = false
	-- Below the menu itself, so an open panel is never covered by its own buttons.
	screen.DisplayOrder = 4
	screen.Parent = playerGui

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.new(0, EDGE_MARGIN, 0.5, 0)
	bar.Size = UDim2.fromOffset(TILE + LABEL_WIDTH, #tabs * TILE + math.max(0, #tabs - 1) * SPACING)
	bar.Parent = screen

	local layout = UI.VerticalList(bar, SPACING)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left

	for index, tab in tabs do
		local button = Instance.new("TextButton")
		button.Name = tab.Id
		button.LayoutOrder = index
		button.Size = UDim2.fromOffset(TILE + LABEL_WIDTH, TILE)
		button.BackgroundColor3 = UI.Palette.Glass
		button.BorderSizePixel = 0
		button.Text = ""
		button.Parent = bar

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = UI.Palette.GlassStroke
		stroke.Parent = button

		-- The tile is a square inset in the button's leading edge. The icon is
		-- drawn into it at scale, so both follow whatever TILE ends up being.
		local tile = Instance.new("Frame")
		tile.Name = "Tile"
		tile.AnchorPoint = Vector2.new(0, 0.5)
		tile.Position = UDim2.new(0, 8, 0.5, 0)
		tile.Size = UDim2.fromOffset(TILE - 16, TILE - 16)
		tile.BackgroundColor3 = UI.Palette.Backdrop
		tile.BorderSizePixel = 0
		tile.Parent = button

		local tileCorner = Instance.new("UICorner")
		tileCorner.CornerRadius = UDim.new(0, 8)
		tileCorner.Parent = tile

		local inset = Instance.new("UIPadding")
		for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
			(inset :: any)[side] = UDim.new(0.2, 0)
		end
		inset.Parent = tile

		local glyph = Icons.Draw(tab.Icon, tile, UI.Palette.Accent, UI.Palette.Backdrop)

		local label = UI.Label("Label", button)
		label.AnchorPoint = Vector2.new(0, 0.5)
		label.Position = UDim2.new(0, TILE + 2, 0.5, 0)
		label.Size = UDim2.new(0, LABEL_WIDTH - 12, 1, 0)
		label.Font = UI.Font.Heading
		label.TextSize = 15
		label.TextColor3 = UI.Palette.TextMuted
		label.Text = string.upper(tab.DisplayName)

		UI.Pressable(button, {
			OnPress = function()
				EffectsController:Play("UiClick")
			end,
		})

		button.Activated:Connect(function()
			-- Toggling on the id means a second press closes it again, which is
			-- what a button that is always on screen has to do.
			MenuController:Toggle(tab.Id)
		end)

		table.insert(entries, {
			Id = tab.Id,
			Button = button,
			Tile = tile,
			Label = label,
			Glyph = glyph,
			Stroke = stroke,
		})
	end
end

function MenuBarController:Start()
	self:_build()
	self:_refresh(MenuController:GetOpenTab())

	MenuController.Changed:Connect(function(openTab: string?)
		self:_refresh(openTab)
	end)
end

return MenuBarController
