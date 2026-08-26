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
local UserInputService = game:GetService("UserInputService")

local UI = {}

--[[
	The 2D interface is a warm cream theme: paper surfaces, ink-brown text.

	It is deliberately the opposite of the world it sits over. The city is dark,
	gritty and desaturated, and a dark HUD on top of it competes with the scenery
	for the same narrow band of greys — the map board (MapRender.Paper) already had
	to break out to paper for exactly that reason, and this extends that decision to
	the rest of the interface rather than leaving one light panel in a dark suite.

	Two rules keep an inverted theme from going wrong, and both are why the semantic
	tokens below exist rather than just new values on the old names:

	  * A surface colour is not a text colour. The dark theme could get away with
	    painting ink as `Backdrop` because the backdrop happened to be near-black;
	    on cream that silently turns light-on-light. Anything drawn *on* a filled
	    accent chip uses `OnAccent`, and anything drawn on a panel uses `Text`.
	  * The stroke inverts. A dark panel is rimmed with a lighter line to catch an
	    edge; a light panel needs a darker one, and at lower transparency, or the
	    border disappears into the fill.

	Accents are also darkened from their dark-theme values. The old amber (255,196,61)
	is a fine glow on near-black and close to illegible as text on cream.
]]
UI.Palette = {
	-- Paper base. Shared with MapRender's board so the map does not read as a
	-- different material from the panel holding it.
	Backdrop = Color3.fromRGB(232, 228, 216),
	Glass = Color3.fromRGB(252, 249, 240),
	GlassStroke = Color3.fromRGB(150, 138, 116),

	Text = Color3.fromRGB(38, 33, 26),
	TextMuted = Color3.fromRGB(122, 112, 95),

	-- What sits on top of a filled accent/stat chip. Never reuse Backdrop for this.
	OnAccent = Color3.fromRGB(252, 249, 240),
	-- Explicit surface names, so nothing has to press a backdrop into service as a
	-- panel fill or a border again.
	Surface = Color3.fromRGB(252, 249, 240),
	SurfaceRaised = Color3.fromRGB(255, 253, 248),
	Border = Color3.fromRGB(150, 138, 116),

	Accent = Color3.fromRGB(178, 108, 12),
	Power = Color3.fromRGB(158, 92, 8),
	Token = Color3.fromRGB(16, 112, 138),
	FightToken = Color3.fromRGB(186, 74, 16),

	Health = Color3.fromRGB(178, 44, 40),
	-- The healthy part of the health bar. Health above stays the colour of the part that
	-- is gone, so a bar reads as "this much left, that much taken" rather than as one
	-- block whose length you have to judge against a track.
	Vital = Color3.fromRGB(44, 138, 62),
	Combo = Color3.fromRGB(186, 74, 16),

	Danger = Color3.fromRGB(184, 36, 36),

	-- "This is the one to pick" affirmatives, as a filled chip and as the ink and rim
	-- that go on it. The weight panel used to spell these out as literals, which meant
	-- it was the one panel a theme change could not reach.
	Success = Color3.fromRGB(30, 108, 58),
	SuccessInk = Color3.fromRGB(240, 252, 243),
	SuccessEdge = Color3.fromRGB(46, 148, 80),
	-- The filled version of Danger, for a chip rather than a word.
	DangerFill = Color3.fromRGB(146, 40, 44),

	-- Legacy names retained for callers, now used as small highlights inside the
	-- restrained cream menu rather than as full saturated card surfaces.
	CartoonInk = Color3.fromRGB(52, 45, 36),
	CartoonCream = Color3.fromRGB(255, 247, 218),
	CartoonLime = Color3.fromRGB(58, 132, 40),
	CartoonPink = Color3.fromRGB(176, 46, 104),
}

--[[
	Fill opacity, kept here rather than inline because it is theme-dependent.

	A translucent panel over a bright world washes out far faster than the same panel
	over a dark one, so the cream theme runs its surfaces much closer to opaque than
	the glassmorphism the dark theme could afford.
]]
UI.Surfaces = {
	PanelTransparency = 0.04,
	CardTransparency = 0,
	StrokeTransparency = 0.35,
	-- The dimmer behind a modal. Inverted: a light theme dims by veiling toward the
	-- ink, not by adding more black to an already-black backdrop.
	ScrimTransparency = 0.45,
	BarTrackTransparency = 0.18,
}

--[[
	The dark counterpart, for chrome rather than content.

	The cream theme is right for a panel you *read* — a menu tab full of stat rows and
	shop cards. It is wrong for the chrome that sits permanently over the world: a
	always-on cream slab in the corner of the screen competes with the game behind it,
	and the HUD's job is to be legible without being the brightest thing on screen.

	So the two live side by side. `UI.Palette` stays the default every helper paints
	from, which keeps the ~60 menu call sites light without touching one of them, and a
	panel opts into this table by calling `UI.ApplyTheme` once it is built.

	Same key names as `UI.Palette` throughout — that is what lets `ApplyTheme` be a
	lookup rather than a special case per element. Accents are the brighter pre-cream
	values, because on near-black they need to glow rather than carry contrast.
]]
UI.Dark = {
	Backdrop = Color3.fromRGB(14, 15, 20),
	Glass = Color3.fromRGB(30, 33, 44),
	GlassStroke = Color3.fromRGB(120, 130, 160),

	Text = Color3.fromRGB(240, 243, 250),
	TextMuted = Color3.fromRGB(150, 158, 178),

	-- On a filled accent chip the ink goes dark again, because the chip is bright.
	OnAccent = Color3.fromRGB(14, 15, 20),
	Surface = Color3.fromRGB(30, 33, 44),
	SurfaceRaised = Color3.fromRGB(38, 42, 55),
	Border = Color3.fromRGB(120, 130, 160),

	Accent = Color3.fromRGB(255, 196, 61),
	Power = Color3.fromRGB(255, 214, 102),
	Token = Color3.fromRGB(126, 231, 255),
	FightToken = Color3.fromRGB(255, 138, 61),

	Health = Color3.fromRGB(239, 83, 80),
	Vital = Color3.fromRGB(88, 202, 106),
	Combo = Color3.fromRGB(255, 138, 61),

	Danger = Color3.fromRGB(255, 92, 92),

	Success = Color3.fromRGB(35, 126, 70),
	SuccessInk = Color3.fromRGB(210, 255, 221),
	SuccessEdge = Color3.fromRGB(87, 214, 123),
	DangerFill = Color3.fromRGB(91, 38, 42),

	CartoonInk = Color3.fromRGB(35, 34, 52),
	CartoonCream = Color3.fromRGB(255, 247, 218),
	CartoonLime = Color3.fromRGB(154, 236, 91),
	CartoonPink = Color3.fromRGB(255, 108, 176),

	-- A dark panel over a bright world can afford the glassmorphism the cream one
	-- cannot, so the transparencies travel with the palette rather than beside it.
	Surfaces = {
		PanelTransparency = 0.25,
		CardTransparency = 0.08,
		StrokeTransparency = 0.7,
		ScrimTransparency = 0.35,
		BarTrackTransparency = 0.35,
	},
}

UI.Font = {
	Heading = Enum.Font.GothamBold,
	-- One clear face everywhere. The HUD's QUESTS button proved more legible than the
	-- mixed Medium/Black treatment, especially after viewport scaling.
	Body = Enum.Font.GothamBold,
	Numeric = Enum.Font.GothamBold,
	-- The one exception, and it is a narrow one: a small readout printed on top of a
	-- filled bar. The rule above is about headings and body text, where a heavier face
	-- survives scaling; at 13px on a coloured fill bold closes up the counters and the
	-- number reads as a smudge rather than a figure.
	Readout = Enum.Font.Gotham,
}

local CORNER_RADIUS = UDim.new(0, 10)

--[[
	Which palette entry a given object was painted from.

	`ApplyTheme` has to know what a colour *meant* in order to restate it in another
	theme, and the finished instance cannot tell it: a frame filled with `Glass` and a
	frame filled with a stat's own colour are both just a BackgroundColor3 afterwards.
	Re-deriving the intent by comparing against the palette would repaint every one of
	those deliberate stat colours the moment one happened to match.

	So the helpers record the intent as they paint. The attribute names a palette key,
	and re-theming is a lookup.
]]
-- One attribute per thing a caller can paint. They are separate rather than one
-- "colour" role because a button owns a fill, its own ink and a stroke at the same
-- time, and a single attribute would have to guess which of the three was meant.
export type Roles = {
	-- Palette key for text (TextLabel/Button/Box) or, on a plain Frame, its fill.
	Ink: string?,
	-- Palette key for BackgroundColor3, when the object also carries text.
	Fill: string?,
	-- Palette key for a child UIStroke's colour.
	Stroke: string?,
	-- UI.Surfaces key for BackgroundTransparency.
	Opacity: string?,
}

local ROLE_ATTRIBUTES: { [string]: string } = {
	Ink = "UIRoleInk",
	Fill = "UIRoleFill",
	Stroke = "UIRoleStroke",
	Opacity = "UIRoleOpacity",
}

--[[
	Records which palette entries `object` was painted from, so `ApplyTheme` can
	restate them in another theme.

	Exported because the panels that build their own frames — the menu bar, the weight
	rows — need the same bookkeeping as the shared helpers, and a second private copy
	of it in each controller is how the two drift apart.
]]
function UI.Role(object: Instance, roles: Roles): Instance
	for field, attribute in ROLE_ATTRIBUTES do
		local value = (roles :: any)[field]
		if value ~= nil then
			object:SetAttribute(attribute, value)
		end
	end
	return object
end

--[[
	Repaints an already-built subtree in `theme`, following the roles the helpers left.

	Call it once at the end of a `_build`. Anything without a role attribute is left
	exactly as it is, which is the point: a stat colour, a rank colour or a hand-picked
	highlight stays itself, and only the chrome moves.

	Panels that repaint themselves per frame (the weight rows, the menu bar's open and
	closed states) cannot rely on this alone — they have to read the same theme table
	when they recolour, or the next refresh puts the light values straight back.
]]
function UI.ApplyTheme(root: Instance, theme: { [string]: any })
	local surfaces = theme.Surfaces or UI.Surfaces

	local function lookup(object: Instance, field: string): Color3?
		local key = object:GetAttribute(ROLE_ATTRIBUTES[field])
		return if type(key) == "string" then theme[key] else nil
	end

	local function paint(object: Instance)
		local ink = lookup(object, "Ink")
		if ink ~= nil then
			if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
				(object :: TextLabel).TextColor3 = ink
			elseif object:IsA("UIStroke") then
				object.Color = ink
			elseif object:IsA("GuiObject") then
				-- A frame has no text, so its one colour is its fill.
				object.BackgroundColor3 = ink
			end
		end

		local fill = lookup(object, "Fill")
		if fill ~= nil and object:IsA("GuiObject") then
			object.BackgroundColor3 = fill
		end

		local strokeColour = lookup(object, "Stroke")
		if strokeColour ~= nil and object:IsA("GuiObject") then
			local stroke = object:FindFirstChildOfClass("UIStroke")
			if stroke ~= nil then
				stroke.Color = strokeColour
			end
		end

		local opacityKey = object:GetAttribute(ROLE_ATTRIBUTES.Opacity)
		if type(opacityKey) == "string" and object:IsA("GuiObject") then
			local value = surfaces[opacityKey]
			if value ~= nil then
				object.BackgroundTransparency = value
			end
		end
	end

	paint(root)
	for _, descendant in root:GetDescendants() do
		paint(descendant)
	end
end

--[[
	The glass surface every panel sits on: translucent fill, light stroke, rounded,
	padded. `parent` may be nil so callers can build a tree before parenting.
]]
function UI.Panel(name: string, parent: Instance?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = UI.Palette.Glass
	frame.BackgroundTransparency = UI.Surfaces.PanelTransparency
	frame.BorderSizePixel = 0
	UI.Role(frame, { Ink = "Glass", Opacity = "PanelTransparency" })

	local corner = Instance.new("UICorner")
	corner.CornerRadius = CORNER_RADIUS
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI.Palette.Border
	stroke.Transparency = UI.Surfaces.StrokeTransparency
	stroke.Thickness = 1
	UI.Role(stroke, { Ink = "Border" })
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
	The shared menu card. The name is retained for compatibility, but the visual is a
	clean GTA-style dark surface: a thin stat-coloured rail and border carry identity
	without filling every page with saturated gradients. Info, transformations, quests
	and the shop all use this helper, so they remain one coherent interface.
]]
function UI.CartoonCard(name: string, accent: Color3, parent: Instance?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = UI.Palette.SurfaceRaised
	frame.BackgroundTransparency = UI.Surfaces.CardTransparency
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 7)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Name = "CartoonStroke"
	stroke.Color = accent
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = frame

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, accent:Lerp(UI.Palette.SurfaceRaised, 0.86)),
		ColorSequenceKeypoint.new(0.2, UI.Palette.SurfaceRaised),
		ColorSequenceKeypoint.new(1, UI.Palette.Backdrop:Lerp(UI.Palette.SurfaceRaised, 0.35)),
	})
	gradient.Rotation = 0
	gradient.Parent = frame

	local rail = Instance.new("Frame")
	rail.Name = "AccentRail"
	rail.Size = UDim2.new(0, 4, 1, 0)
	rail.BackgroundColor3 = accent
	rail.BackgroundTransparency = 0.04
	rail.BorderSizePixel = 0
	rail.ZIndex = 2
	rail.Parent = frame

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
	UI.Role(label, { Ink = "Text" })
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
	How high above an adornee a billboard has to float to clear the whole figure.

	The plate hangs off one part — a head, a torso — but has to clear the entire model,
	and the two are only the same height on a figure that happens to be built that way.
	A boss is 2.1 times a goblin, so a fixed offset either buries the plate in its horns
	or leaves it hanging in the sky above a goblin.

	`headroom` is the gap left above the model's own top.
]]
function UI.HeadroomOffset(model: Instance, adornee: BasePart, headroom: number): Vector3
	if model:IsA("Model") then
		local boundsCFrame, boundsSize = model:GetBoundingBox()
		local top = boundsCFrame.Position.Y + boundsSize.Y / 2
		return Vector3.new(0, (top - adornee.Position.Y) + headroom, 0)
	end
	return Vector3.new(0, adornee.Size.Y / 2 + headroom, 0)
end

--[[
	A labelled progress bar. Returns a Set function rather than exposing the fill, so
	callers cannot forget to clamp the ratio.
]]
function UI.Bar(name: string, color: Color3, parent: Instance?, emptyColor: Color3?): Bar
	local root = Instance.new("Frame")
	root.Name = name
	-- The track behind the fill. Normally the backdrop, so an empty bar reads as an
	-- empty slot; a bar that passes `emptyColor` paints the missing part instead, which
	-- is what health wants — green for what is left, red for what has been taken.
	root.BackgroundColor3 = emptyColor or UI.Palette.Backdrop
	root.BackgroundTransparency = if emptyColor ~= nil then 0.1 else UI.Surfaces.BarTrackTransparency
	root.BorderSizePixel = 0
	-- Only an untinted track follows the theme. A bar that named its own empty colour
	-- did so to mean something — health lost, not "the surface behind the fill".
	if emptyColor == nil then
		UI.Role(root, { Ink = "Backdrop", Opacity = "BarTrackTransparency" })
	end
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

-- Shared by every press-feedback tween in this module: buttons, and the slider knob.
-- Hoisted above Slider because it uses them too, and two copies of an easing curve is
-- how two controls start feeling subtly different.
local PRESS_IN = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_OUT = TweenInfo.new(0.13, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local KNOB_SIZE = 18
-- Space kept clear to the right of the readout, and the margin used to decide when the
-- fill has reached it.
local CAPTION_INSET = 26

export type Slider = {
	Root: TextButton,
	-- Moves the handle without firing OnChanged. For pushing saved state in.
	Set: (value: number) -> (),
}

export type SliderOptions = {
	-- Inclusive whole-number range. Defaults to 0..100.
	Min: number?,
	Max: number?,
	Value: number?,
	Colour: Color3?,
	-- Fired continuously while dragging, with the whole-number value.
	OnChanged: ((value: number) -> ())?,
	-- Fired once when the drag ends. This is the one to persist from: OnChanged can
	-- fire every frame, and a remote call per frame is a rate-limit ban.
	OnCommitted: ((value: number) -> ())?,
}

--[[
	A draggable 0-100 track, shaped like `UI.Bar` so a slider and a readout read as the
	same control family.

	The split between `OnChanged` and `OnCommitted` is the important part of the API and
	exists because of `Net`'s rate limits: dragging fires on every frame the pointer
	moves, so the *local* mix follows the handle live while only the release writes to
	the server. A single callback would force every caller to rediscover that, and the
	first one to forget would spend a player's whole budget in one drag.

	It is a TextButton rather than a Frame so the whole track is one input target — a
	press anywhere on it jumps the handle there, which is what a player expects and what
	a handle-only hit area does not give you on a phone.

	The knob is not decoration. Without one there is nothing on screen that looks
	grabbable, and a bare filled bar reads as a progress meter — something the game is
	telling you — rather than a control you are meant to drag.
]]
function UI.Slider(name: string, parent: Instance?, options: SliderOptions?): Slider
	local settings: SliderOptions = options or {}
	local minimum = settings.Min or 0
	local maximum = settings.Max or 100
	local colour = settings.Colour or UI.Palette.Accent

	local root = Instance.new("TextButton")
	root.Name = name
	root.AutoButtonColor = false
	root.Text = ""
	root.BackgroundColor3 = UI.Palette.Backdrop
	root.BackgroundTransparency = UI.Surfaces.BarTrackTransparency
	root.BorderSizePixel = 0
	root.Size = UDim2.new(1, 0, 0, 22)
	root.ClipsDescendants = false
	UI.Role(root, { Ink = "Backdrop", Opacity = "BarTrackTransparency" })

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = root

	-- The track needs an edge of its own. Against a panel of a similar value an
	-- unstroked trough disappears, and the empty right-hand side stops reading as part
	-- of the control at all.
	local trackStroke = Instance.new("UIStroke")
	trackStroke.Color = UI.Palette.GlassStroke
	trackStroke.Thickness = 1
	trackStroke.Transparency = 0.4
	trackStroke.Parent = root
	UI.Role(trackStroke, { Stroke = "GlassStroke" })

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = colour
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ClipsDescendants = true
	fill.Parent = root

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 6)
	fillCorner.Parent = fill

	-- Lightened at the left, full strength at the right, so the fill has somewhere to
	-- travel to. The same three-stop shape CartoonCard uses, for the same reason.
	local fillGradient = Instance.new("UIGradient")
	fillGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, colour:Lerp(UI.Palette.OnAccent, 0.3)),
		ColorSequenceKeypoint.new(0.55, colour),
		ColorSequenceKeypoint.new(1, colour:Lerp(UI.Palette.CartoonInk, 0.16)),
	})
	fillGradient.Parent = fill

	-- The top-edge highlight the HUD stat chips use. Two pixels of lighter colour is
	-- the difference between a painted rectangle and something with a surface.
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = UI.Palette.OnAccent
	shine.BackgroundTransparency = 0.55
	shine.BorderSizePixel = 0
	shine.Position = UDim2.fromOffset(0, 2)
	shine.Size = UDim2.new(1, 0, 0, 2)
	shine.ZIndex = 2
	shine.Parent = fill

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Size = UDim2.fromOffset(KNOB_SIZE, KNOB_SIZE)
	knob.BackgroundColor3 = UI.Palette.OnAccent
	knob.BorderSizePixel = 0
	knob.ZIndex = 3
	knob.Parent = root
	UI.Role(knob, { Ink = "OnAccent" })

	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local knobStroke = Instance.new("UIStroke")
	knobStroke.Color = colour
	knobStroke.Thickness = 3
	knobStroke.Parent = knob

	local knobScale = Instance.new("UIScale")
	knobScale.Parent = knob

	local caption = UI.Label("Caption", root)
	caption.Size = UDim2.new(1, -(CAPTION_INSET + 8), 1, 0)
	caption.Position = UDim2.fromOffset(8, 0)
	caption.Font = UI.Font.Readout
	caption.TextSize = 13
	caption.TextXAlignment = Enum.TextXAlignment.Right
	-- Above the fill and the knob both, or the number vanishes under the handle at the
	-- top of the range.
	caption.ZIndex = 4
	-- No text stroke. The badges that carry one sit over open sky and need it; this
	-- number sits on an opaque fill that already separates it from the page, so an
	-- outline only thickens glyphs that are small enough to close up.

	root.Parent = parent

	local current = math.clamp(settings.Value or minimum, minimum, maximum)
	local dragging = false
	local releaseConnection: RBXScriptConnection? = nil

	local function ratioOf(): number
		local span = math.max(1, maximum - minimum)
		return (current - minimum) / span
	end

	local function render()
		local ratio = ratioOf()
		fill.Size = UDim2.fromScale(ratio, 1)
		-- Travel is inset by the knob's own radius, so at 0 and 100 the handle sits
		-- inside the trough instead of hanging half of itself off the end. The fill
		-- still runs edge to edge; only the handle is pulled in.
		knob.Position = UDim2.new(ratio, (0.5 - ratio) * KNOB_SIZE, 0.5, 0)
		-- The unit is the whole point of the readout. "72" could be anything.
		caption.Text = `{current}%`

		--[[
			The readout is right-aligned, so a nearly-full bar slides its own fill
			underneath it — and dark ink on a dark fill is unreadable. It flips to the
			on-accent colour exactly when the fill reaches it.

			Measured against the text's own width rather than a guessed ratio: "7%" and
			"100%" are covered at different points, and a fixed threshold gets one of
			them wrong. An outline used to paper over this; it also thickened the glyphs
			enough to be the reason this readout was hard to read in the first place.
		]]
		local trackWidth = math.max(1, root.AbsoluteSize.X)
		local reach = caption.TextBounds.X + CAPTION_INSET
		caption.TextColor3 = if ratio * trackWidth > trackWidth - reach
			then UI.Palette.OnAccent
			else UI.Palette.Text
	end

	local function scaleKnob(target: number, info: TweenInfo)
		TweenService:Create(knobScale, info, { Scale = target }):Play()
	end

	local function commit()
		if settings.OnCommitted ~= nil then
			settings.OnCommitted(current)
		end
	end

	local function setValue(value: number)
		local clamped = math.clamp(math.round(value), minimum, maximum)
		if clamped == current then
			return
		end
		current = clamped
		render()
		if settings.OnChanged ~= nil then
			settings.OnChanged(current)
		end
	end

	local function valueAt(x: number): number
		local left = root.AbsolutePosition.X
		local width = math.max(1, root.AbsoluteSize.X)
		local ratio = math.clamp((x - left) / width, 0, 1)
		return math.round(minimum + ratio * (maximum - minimum))
	end

	local function stopDragging()
		if not dragging then
			return
		end
		dragging = false
		scaleKnob(1, PRESS_OUT)
		if releaseConnection ~= nil then
			releaseConnection:Disconnect()
			releaseConnection = nil
		end
		commit()
	end

	root.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if not dragging then
				scaleKnob(1.15, PRESS_IN)
			end
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		dragging = true
		scaleKnob(1.25, PRESS_IN)
		setValue(valueAt(input.Position.X))

		--[[
			Connected per drag rather than once per slider.

			This used to be a permanent UserInputService.InputEnded connection made at
			construction and never disconnected, so every rebuild of the settings page
			leaked one listener for the lifetime of the session. Bound on the way down
			and dropped on the way up, there is no global listener at all while nobody
			is dragging.

			It still has to be UserInputService rather than the track's own InputEnded:
			a drag that ends off the side of the control must commit, or the value
			silently reverts on the next redraw.
		]]
		if releaseConnection == nil then
			releaseConnection = UserInputService.InputEnded:Connect(function(ended: InputObject)
				if
					ended.UserInputType == Enum.UserInputType.MouseButton1
					or ended.UserInputType == Enum.UserInputType.Touch
				then
					stopDragging()
				end
			end)
		end
	end)

	root.InputChanged:Connect(function(input: InputObject)
		--[[
			No wheel-to-nudge here, though it is the obvious thing to add.

			Every slider in this game lives on a scrolling page, and the wheel over a
			track would both nudge the value and scroll the list under it. Measured: of
			three notches, one moved the page and two moved the volume. A control that
			quietly changes a player's audio while they scroll past it is worse than one
			that only responds to being dragged.
		]]
		if not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		setValue(valueAt(input.Position.X))
	end)

	root.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseMovement and not dragging then
			scaleKnob(1, PRESS_OUT)
		end
	end)

	render()

	return {
		Root = root,
		Set = function(value: number)
			current = math.clamp(math.round(value), minimum, maximum)
			render()
		end,
	}
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

-- Called once per press, for whoever wants to make a noise about it.
local pressListener: (() -> ())? = nil

--[[
	Registers the one thing that happens on every button press in the game — in practice
	EffectsController, playing the click.

	It is a hook rather than a direct call because UI lives in ReplicatedStorage and must
	not depend on a client controller. Inverting it this way keeps UI free of that
	dependency while still meaning a new button is audible the moment it exists: the
	previous arrangement hand-wired a click onto individual buttons, which is why most of
	the menu was silent — being heard was opt-in, and nobody opted in.
]]
function UI.SetPressListener(listener: (() -> ())?)
	pressListener = listener
end

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
		if pressListener ~= nil then
			-- A listener that throws must never stop the button working.
			pcall(pressListener :: () -> ())
		end
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

local POP_UP = TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local POP_DOWN = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE = TweenInfo.new(0.62, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)

--[[
	The one `UIScale` an object is animated by.

	Reused rather than added, because a second UIScale on the same instance is silently
	ignored — two animations that each make their own would look like one of them had
	simply stopped working.
]]
local function scaleOf(object: GuiObject): UIScale
	local existing = object:FindFirstChildOfClass("UIScale")
	if existing ~= nil then
		return existing
	end

	local scale = Instance.new("UIScale")
	scale.Parent = object
	return scale
end

--[[
	A one-shot punch: overshoot, then settle back to normal size.

	Note that this drives the same UIScale as UI.Pressable, so do not point the two at
	one instance — Pressable's settle would cut the pop short. On a button, pop the
	contents (its icon, its label) and let Pressable own the button itself.
]]
function UI.Pop(object: GuiObject, strength: number?)
	local scale = scaleOf(object)
	local up = TweenService:Create(scale, POP_UP, { Scale = 1 + (strength or 0.22) })
	up.Completed:Connect(function()
		if object.Parent ~= nil then
			TweenService:Create(scale, POP_DOWN, { Scale = 1 }):Play()
		end
	end)
	up:Play()
end

--[[
	A slow breathe that runs until it is told to stop, for the one thing on screen that
	is currently happening. Returns the stopper; calling it restores the normal size.

	Deliberately gentle and deliberately slow: this sits under the player's eyeline for
	minutes at a time while they train, and anything faster becomes something to look
	away from.
]]
function UI.Pulse(object: GuiObject, strength: number?): () -> ()
	local scale = scaleOf(object)
	local tween = TweenService:Create(scale, PULSE, { Scale = 1 + (strength or 0.1) })
	tween:Play()

	return function()
		tween:Cancel()
		if object.Parent ~= nil then
			TweenService:Create(scale, POP_DOWN, { Scale = 1 }):Play()
		end
	end
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

export type ConfirmOptions = {
	Title: string,
	Body: string,
	ConfirmText: string?,
	CancelText: string?,
	OnConfirm: () -> (),
}

--[[
	A modal yes/no over a dimming scrim.

	This exists because spending is irreversible and the multiplier ladder used to
	buy on the first click of a button whose cost had just changed underneath it —
	the price doubles every level, so a double-click on a cheap upgrade could spend
	several times what the player read.

	The scrim is a real button, not a decorative frame. Without one, clicks land on
	whatever is behind the dialog, and on a phone the panel underneath scrolls while
	the modal sits on top of it.

	Presentation only: the server still decides whether the purchase is affordable
	and its reply is what the player is told. Nothing here is a permission check.
]]
function UI.Confirm(parent: Instance, options: ConfirmOptions): Frame
	local scrim = Instance.new("TextButton")
	scrim.Name = "ConfirmScrim"
	scrim.Size = UDim2.fromScale(1, 1)
	-- Veiled toward the ink rather than the paper: dimming a light theme with more
	-- light does nothing, so the scrim is the dark end of the palette.
	scrim.BackgroundColor3 = UI.Palette.CartoonInk
	scrim.BackgroundTransparency = UI.Surfaces.ScrimTransparency
	scrim.BorderSizePixel = 0
	scrim.AutoButtonColor = false
	scrim.Text = ""
	-- Above whatever it is covering, whatever that happens to be.
	scrim.ZIndex = 50
	scrim.Parent = parent

	local dialog = UI.Panel("Confirm", scrim)
	dialog.AnchorPoint = Vector2.new(0.5, 0.5)
	dialog.Position = UDim2.fromScale(0.5, 0.5)
	dialog.Size = UDim2.fromOffset(400, 184)
	dialog.BackgroundTransparency = 0
	dialog.ZIndex = 51

	local dialogStroke = dialog:FindFirstChildOfClass("UIStroke")
	if dialogStroke ~= nil then
		dialogStroke.Color = UI.Palette.Accent
		dialogStroke.Transparency = 0.2
		dialogStroke.Thickness = 2
	end

	local title = UI.Label("Title", dialog)
	title.Size = UDim2.new(1, 0, 0, 28)
	title.Font = UI.Font.Heading
	title.TextSize = 17
	title.TextColor3 = UI.Palette.Accent
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Text = options.Title
	title.ZIndex = 51

	local body = UI.Label("Body", dialog)
	body.Position = UDim2.fromOffset(6, 36)
	body.Size = UDim2.new(1, -12, 0, 76)
	body.TextSize = 14
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Center
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.Text = options.Body
	body.ZIndex = 51

	local function choice(name: string, text: string, color: Color3, onPress: () -> ()): TextButton
		local button = Instance.new("TextButton")
		button.Name = name
		button.Size = UDim2.new(0.5, -6, 0, 34)
		button.BackgroundColor3 = color
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Font = UI.Font.Heading
		button.TextSize = 14
		button.TextColor3 = UI.Palette.OnAccent
		button.Text = text
		button.ZIndex = 51
		button.Parent = dialog

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 7)
		corner.Parent = button

		UI.Pressable(button)
		button.Activated:Connect(onPress)
		return button
	end

	local function close()
		scrim:Destroy()
	end

	local confirm = choice("Confirm", options.ConfirmText or "Confirm", UI.Palette.Vital, function()
		close()
		options.OnConfirm()
	end)
	confirm.Position = UDim2.new(0, 0, 1, -34)

	local cancel = choice("Cancel", options.CancelText or "Cancel", UI.Palette.FightToken, close)
	cancel.Position = UDim2.new(0.5, 6, 1, -34)

	scrim.Activated:Connect(close)

	return dialog
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
