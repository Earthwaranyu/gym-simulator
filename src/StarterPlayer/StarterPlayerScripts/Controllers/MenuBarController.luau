--!strict
--[[
	MenuBarController — one persistent MENU button.

	The reference experience uses one strong menu entry and leaves the action HUD
	compact. This project follows that hierarchy without copying its artwork: one
	original map-pin tile opens the full tabbed menu, while the five stat routes are
	always available from HudController's bottom training dock.

	The button stays on the right edge above Roblox's jump corner, uses a 56-pixel
	touch target, and visibly fills with the accent colour whenever any menu tab is
	open. Keyboard M and every internal tab continue to work unchanged.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

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
-- Where the HUD's top-left block ends. The bar never starts above this.
local HUD_BLOCK = 108
-- On a touch device the bottom of the screen belongs to Roblox: the movement
-- thumbstick bottom-left and the jump button bottom-right. Measured generously,
-- because a button a thumb *nearly* hits is worse than one it cannot reach.
local TOUCH_RESERVED_BOTTOM = 0.6

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
local screenGui: ScreenGui
local bar: Frame
local layout: UIListLayout
local barScale: UIScale

-- Anchor is the y of the column's centre, or of the strip's top edge.
export type Plan = { Mode: string, Scale: number, Anchor: number }

--[[
	Decides how the bar is laid out on a given screen. Pure, so it can be checked
	against a table of real device sizes without a device to hand.

	The helper remains count-driven so the control can grow without another layout
	rewrite. A short screen uses a horizontal strip if a future update adds entries;
	the current one-button build naturally stays a full labelled touch target.

	The mode is computed from the geometry rather than switched on `TouchEnabled`,
	so a large tablet keeps the column it has room for.
]]
function MenuBarController._plan(viewportHeight: number, count: number, touch: boolean): Plan
	local scale = UI.LayoutScale(viewportHeight)
	local column = count * TILE + math.max(0, count - 1) * SPACING

	-- The window the bar is allowed to occupy: below the HUD block, and above the
	-- touch controls if there are any.
	local top = HUD_BLOCK * scale + EDGE_MARGIN
	local bottom = if touch then viewportHeight * TOUCH_RESERVED_BOTTOM else viewportHeight - EDGE_MARGIN
	local window = bottom - top

	-- Centred in the window rather than in the viewport. Centring on the viewport
	-- is what a first version did, and on a tablet it pushed a column that had
	-- been *sized* to fit the window straight back down through the bottom of it.
	if column * scale <= window then
		local half = column * scale / 2
		return {
			Mode = "Column",
			Scale = scale,
			Anchor = math.clamp(viewportHeight / 2, top + half, bottom - half),
		}
	end

	-- Nearly fits: shrink rather than change shape.
	local fitting = window / column
	if fitting >= UI.MIN_LAYOUT_SCALE then
		return { Mode = "Column", Scale = fitting, Anchor = top + column * fitting / 2 }
	end

	return { Mode = "Strip", Scale = scale, Anchor = top }
end

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
		paint(entry, openTab ~= nil)
	end
end

function MenuBarController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- One obvious entry opens the full tabbed menu. The five muscle routes live in
	-- the HUD hotbar, so seven permanent navigation slabs would only add clutter.
	local tabs = {
		{ Id = "Menu", DisplayName = "Menu", Icon = "Map" },
	}

	local screen = Instance.new("ScreenGui")
	screenGui = screen
	screen.Name = "GymMenuBar"
	screen.ResetOnSpawn = false
	-- Matches the HUD, so both live in the same coordinate space and "vertically
	-- centred" means centred in the area the player can actually see.
	screen.IgnoreGuiInset = false
	-- Below the menu itself, so an open panel is never covered by its own buttons.
	screen.DisplayOrder = 4
	screen.Parent = playerGui

	-- Created here, driven by _arrange: the bar's scale is not simply
	-- UI.LayoutScale, because a column that nearly fits is shrunk further to fit
	-- rather than allowed to run into the touch controls.
	barScale = Instance.new("UIScale")
	barScale.Parent = screen

	bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BackgroundTransparency = 1
	bar.Parent = screen

	layout = UI.VerticalList(bar, SPACING)
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
			if MenuController:GetOpenTab() ~= nil then
				MenuController:Toggle()
			else
				MenuController:Open("Map")
			end
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

--[[
	Applies a plan: direction, button width, whether labels show, and where the
	whole thing sits.
]]
function MenuBarController:_arrange()
	-- The ScreenGui's own height, not the camera's: this GUI respects the inset,
	-- so the space it can use is already smaller than the screen.
	local height = screenGui.AbsoluteSize.Y
	if height <= 0 then
		return
	end
	local plan = MenuBarController._plan(height, #entries, UserInputService.TouchEnabled)

	barScale.Scale = plan.Scale
	local column = plan.Mode == "Column"
	local width = if column then TILE + LABEL_WIDTH else TILE

	layout.FillDirection = if column then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal

	for _, entry in entries do
		entry.Button.Size = UDim2.fromOffset(width, TILE)
		-- The label is what does not fit in a strip; the glyph is the part that
		-- has to survive, so the label is what goes.
		entry.Label.Visible = column
	end

	local span = #entries * TILE + math.max(0, #entries - 1) * SPACING
	-- Anchor is in real pixels; the bar's own offsets are multiplied by the
	-- UIScale, so the position has to be divided by it to land where planned.
	local margin = EDGE_MARGIN / plan.Scale

	if column then
		bar.Size = UDim2.fromOffset(width, span)
		bar.AnchorPoint = Vector2.new(1, 0.5)
	else
		bar.Size = UDim2.fromOffset(span, TILE)
		bar.AnchorPoint = Vector2.new(1, 0.5)
	end
	-- Right-side, above the jump-control corner and clear of the bottom stat dock.
	bar.Position = UDim2.new(1, -margin, 0.62, 0)
end

function MenuBarController:Start()
	self:_build()
	self:_arrange()
	self:_refresh(MenuController:GetOpenTab())

	MenuController.Changed:Connect(function(openTab: string?)
		self:_refresh(openTab)
	end)

	screenGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		self:_arrange()
	end)
end

return MenuBarController
