--!strict
--[[
	UI — shared building blocks for every screen in the game.

	Per skills.md "Bold-Frontend-Design": glassmorphism, a committed palette, real
	typography rather than default Arial, and UICorner / UIPadding /
	UIAspectRatioConstraint applied as a matter of course rather than as an
	afterthought.

	Building panels through these helpers rather than by hand is also what keeps a
	restyle to one file — the HUD never names a colour or a corner radius itself.
]]

local TweenService = game:GetService("TweenService")

local UI = {}

UI.Palette = {
	-- Deep neutral base, so the accent colours carry all the meaning.
	Backdrop = Color3.fromRGB(14, 15, 20),
	Glass = Color3.fromRGB(30, 33, 44),
	GlassStroke = Color3.fromRGB(120, 130, 160),

	Text = Color3.fromRGB(240, 243, 250),
	TextMuted = Color3.fromRGB(150, 158, 178),

	Accent = Color3.fromRGB(255, 196, 61),
	Power = Color3.fromRGB(255, 214, 102),
	Token = Color3.fromRGB(126, 231, 255),

	Health = Color3.fromRGB(239, 83, 80),
	Combo = Color3.fromRGB(255, 138, 61),

	Danger = Color3.fromRGB(255, 92, 92),
}

UI.Font = {
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Numeric = Enum.Font.GothamBlack,
}

local CORNER_RADIUS = UDim.new(0, 10)

--[[
	The glass surface every panel sits on: translucent fill, light stroke, rounded,
	padded. `parent` may be nil so callers can build a tree before parenting.
]]
function UI.Panel(name: string, parent: Instance?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = UI.Palette.Glass
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0

	local corner = Instance.new("UICorner")
	corner.CornerRadius = CORNER_RADIUS
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI.Palette.GlassStroke
	stroke.Transparency = 0.7
	stroke.Thickness = 1
	stroke.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.Parent = frame

	frame.Parent = parent
	return frame
end

--[[
	A text label. Defaults to left-aligned body text that scales with its box, which
	is what almost every label in the HUD wants.
]]
function UI.Label(name: string, parent: Instance?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Font = UI.Font.Body
	label.TextColor3 = UI.Palette.Text
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.RichText = true
	label.Text = ""
	label.Parent = parent
	return label
end

export type Bar = {
	Root: Frame,
	Fill: Frame,
	Caption: TextLabel,
	-- Sets fill from a 0..1 ratio and updates the caption text.
	Set: (ratio: number, caption: string) -> (),
}

--[[
	A labelled progress bar. Returns a Set function rather than exposing the fill, so
	callers cannot forget to clamp the ratio.
]]
function UI.Bar(name: string, color: Color3, parent: Instance?): Bar
	local root = Instance.new("Frame")
	root.Name = name
	root.BackgroundColor3 = UI.Palette.Backdrop
	root.BackgroundTransparency = 0.35
	root.BorderSizePixel = 0
	root.Size = UDim2.new(1, 0, 0, 22)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = root

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	fill.Parent = root

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	local caption = UI.Label("Caption", root)
	caption.Size = UDim2.new(1, -16, 1, 0)
	caption.Position = UDim2.fromOffset(8, 0)
	caption.Font = UI.Font.Numeric
	caption.TextSize = 13
	caption.ZIndex = 2

	root.Parent = parent

	local bar: Bar = {
		Root = root,
		Fill = fill,
		Caption = caption,
		Set = function(ratio: number, text: string)
			fill.Size = UDim2.fromScale(math.clamp(ratio, 0, 1), 1)
			caption.Text = text
		end,
	}

	return bar
end

--[[
	Stacks children vertically with consistent spacing. Used instead of manual
	positioning so a row can be added or removed without re-laying-out its siblings.
]]
function UI.VerticalList(parent: Instance, spacing: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, spacing)
	layout.Parent = parent
	return layout
end

export type PressableOptions = {
	-- How far the button shrinks at the bottom of a press.
	PressScale: number?,
	-- How far it grows when the pointer is over it. 1 disables the lift, which is
	-- what a touch-only control wants — there is no hover on a finger.
	HoverScale: number?,
	-- Called once per press, on the way down rather than on release, so the
	-- feedback lands at the moment the finger does.
	OnPress: (() -> ())?,
}

local PRESS_IN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_OUT = TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	Makes a button feel like one: it grows slightly under the pointer and shrinks
	under a press, and springs back when released or when the pointer leaves.

	This lives here rather than in the controller that needed it first for the same
	reason UI.Panel does — a restyle should be one file, and "how hard does a button
	press" is styling. It is also the thing the first version of the menu bar was
	missing: `AutoButtonColor` tints by a few percent and nothing else, which on a
	dark theme is invisible, so every press felt like it had not registered.

	`AutoButtonColor` is switched off deliberately. Left on, it fights the tween by
	recolouring the same frames on the same events.

	Returns the `UIScale` it drives, so a caller doing its own sizing can read it
	rather than adding a second one.
]]
function UI.Pressable(button: GuiButton, options: PressableOptions?): UIScale
	-- Annotated, not inferred: `options or {}` otherwise widens to
	-- `PressableOptions | {}` and every field read below fails on the empty half.
	local settings: PressableOptions = options or {}
	local pressScale = settings.PressScale or 0.94
	local hoverScale = settings.HoverScale or 1.03

	button.AutoButtonColor = false

	local scale = button:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = button

	local hovering = false
	local pressing = false

	local function settle()
		local target = if pressing then pressScale elseif hovering then hoverScale else 1
		TweenService:Create(scale, if pressing then PRESS_IN else PRESS_OUT, { Scale = target }):Play()
	end

	button.MouseEnter:Connect(function()
		hovering = true
		settle()
	end)

	button.MouseLeave:Connect(function()
		-- A finger that slides off the button never sends a release to it, so
		-- leaving has to clear the press as well or the tile stays shrunk.
		hovering = false
		pressing = false
		settle()
	end)

	-- InputBegan rather than MouseButton1Down: the mouse events do fire for touch,
	-- but InputBegan is what reports the touch itself, and a control that has to
	-- work on a phone should be listening to the phone.
	button.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		pressing = true
		settle()
		if settings.OnPress ~= nil then
			settings.OnPress()
		end
	end)

	button.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		pressing = false
		settle()
	end)

	return scale
end

-- The screen height every fixed offset in this game was chosen against.
local REFERENCE_HEIGHT = 720
-- Below this the interface would shrink past the point a finger can hit it; above
-- it, a 4K monitor would get a HUD with comic proportions.
local MIN_LAYOUT_SCALE = 0.85
local MAX_LAYOUT_SCALE = 1.25

--[[
	How much to scale fixed-offset interface for the screen it is on.

	Everything in the HUD is written in offsets against a 720-tall screen, which is
	right for a desktop and wrong for everything else. One definition of the factor
	lives here so the HUD and the button bar cannot drift apart and start
	overlapping on one device but not another.
]]
function UI.LayoutScale(viewportHeight: number): number
	return math.clamp(viewportHeight / REFERENCE_HEIGHT, MIN_LAYOUT_SCALE, MAX_LAYOUT_SCALE)
end

UI.MIN_LAYOUT_SCALE = MIN_LAYOUT_SCALE

--[[
	Applies UI.LayoutScale to a whole ScreenGui and keeps it applied when the window
	changes — which on a phone is every rotation, and on a desktop every resize.
]]
function UI.ScaleWithViewport(screen: ScreenGui): UIScale
	local scale = screen:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = screen

	-- The ScreenGui's own size, not the camera's. A GUI that respects the inset
	-- has less room than the screen reports, and scaling off the camera makes two
	-- ScreenGuis with different inset settings disagree about how big a pixel is —
	-- which is how the HUD ended up at 1.04 while the bar beside it was at 0.96.
	local function apply()
		local height = screen.AbsoluteSize.Y
		if height > 0 then
			scale.Scale = UI.LayoutScale(height)
		end
	end

	apply()
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(apply)

	return scale
end

--[[
	Locks an element's shape across screen sizes, which is what keeps square badges
	square on ultrawide monitors and phones alike.
]]
function UI.AspectRatio(parent: Instance, ratio: number): UIAspectRatioConstraint
	local constraint = Instance.new("UIAspectRatioConstraint")
	constraint.AspectRatio = ratio
	constraint.Parent = parent
	return constraint
end

return UI
