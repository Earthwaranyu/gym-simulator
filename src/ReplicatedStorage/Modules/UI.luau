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
