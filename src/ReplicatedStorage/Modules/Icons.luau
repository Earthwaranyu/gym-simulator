--!strict
--[[
	Icons — interface glyphs, drawn rather than uploaded.

	Every other asset in this game is original by rule: machines are built from
	Roblox primitives, training animations are generated from joint angles, and
	nothing references an id somebody else owns. Interface art is the last place
	that rule had not reached, and an icon pack from the Toolbox would have broken
	it for five small pictures.

	So each glyph is assembled from Frames with UICorner, UIStroke and Rotation —
	the GUI equivalent of building a bench press out of blocks and cylinders.

	Two consequences worth knowing:

	  * Everything inside a builder is expressed in SCALE, never in offset. An icon
	    is therefore whatever size its tile is, which is what lets #85 resize the
	    whole bar from the viewport without touching this file.
	  * Shapes are chosen for what survives being 28 pixels tall on a phone. There
	    is no gear and no shopping cart on purpose: a circle of teeth costs a dozen
	    Frames and reads as a grey blob at that size, where three rails and a tick
	    read as settings instantly. Every glyph was checked at size before it
	    shipped — see the note on verification below.

	A new icon is a function plus a key in ICONS. Nothing else changes.

	Checking one is harder than it should be: Studio's screen capture does not
	render GUIs at all, so an icon cannot simply be looked at. The way these were
	checked is `scripts/preview_icons.luau` — it draws the real glyph, reads back
	each Frame's laid-out position, and mirrors it into Parts that the capture CAN
	see. Two icons were wrong when first drawn that way: Shop was a rotated square
	and therefore the same silhouette as Map, and Settings' round knobs merged into
	their rails.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(ReplicatedStorage.Modules.UI)

local Icons = {}

export type Builder = (parent: GuiObject, color: Color3, hole: Color3) -> ()

--[[
	A rectangle in the icon's 0..1 space, centred on (x, y).
]]
local function shape(
	parent: GuiObject,
	name: string,
	x: number,
	y: number,
	width: number,
	height: number,
	color: Color3,
	rotation: number?,
	corner: number?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(width, height)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Rotation = rotation or 0
	frame.Parent = parent

	if corner ~= nil then
		local radius = Instance.new("UICorner")
		radius.CornerRadius = UDim.new(corner, 0)
		radius.Parent = frame
	end

	return frame
end

--[[
	The same rectangle, but drawn in the tile's own colour so it reads as a gap punched
	through the glyph rather than as part of it.

	Marked with an attribute rather than by name. Recolour used to spot knockouts by
	checking for the names "Hole" and "Fold", which quietly missed every knockout called
	something else — the fist's knuckles, the sheet's ruled lines, the crown's notches —
	so a selected tile filled those gaps in with the glyph colour and the shape closed
	up. An attribute cannot be missed by an icon that names its parts honestly.
]]
local function knockout(
	parent: GuiObject,
	name: string,
	x: number,
	y: number,
	width: number,
	height: number,
	hole: Color3,
	rotation: number?,
	corner: number?
): Frame
	local frame = shape(parent, name, x, y, width, height, hole, rotation, corner)
	frame:SetAttribute("Knockout", true)
	return frame
end

--[[
	Map — a marker diamond with the pin hole knocked out of it.
]]
local function drawMap(parent: GuiObject, color: Color3, hole: Color3)
	local body = shape(parent, "Diamond", 0.5, 0.46, 0.6, 0.6, color, 45, 0.16)
	-- Child of the diamond, so it turns with it and stays centred in the shape.
	knockout(body, "Hole", 0.5, 0.5, 0.34, 0.34, hole, 0, 1)
	-- The point below the head, which is what makes it a map pin and not a rhombus.
	shape(parent, "Tip", 0.5, 0.84, 0.16, 0.22, color, 0, 0.4)
end

--[[
	Upgrades — an up arrow: a chevron over a stem.
]]
local function drawUpgrades(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "ChevronLeft", 0.31, 0.36, 0.46, 0.15, color, -45, 1)
	shape(parent, "ChevronRight", 0.69, 0.36, 0.46, 0.15, color, 45, 1)
	shape(parent, "Stem", 0.5, 0.68, 0.15, 0.46, color, 0, 1)
end

--[[
	Shop — a carrier bag: a body with a squared-off handle over it.

	This started as a price tag, which is a rounded square turned on its corner —
	and next to Map, which is a marker turned on its corner, the two were the same
	diamond at a glance. Two icons that need telling apart cannot share a
	silhouette, whatever is punched out of them.
]]
local function drawShop(parent: GuiObject, color: Color3, hole: Color3)
	local body = shape(parent, "Bag", 0.5, 0.64, 0.76, 0.56, color, 0, 0.16)
	knockout(body, "Fold", 0.5, 0.14, 1.0, 0.1, hole, 0, 0)

	-- A handle drawn as three straight pieces, because a GUI cannot draw an arc
	-- and a squared handle reads as a bag where half a circle reads as noise.
	shape(parent, "HandleTop", 0.5, 0.22, 0.34, 0.09, color, 0, 1)
	for _, side in { -1, 1 } do
		shape(parent, `HandleSide{side}`, 0.5 + side * 0.155, 0.29, 0.09, 0.2, color, 0, 1)
	end
end

--[[
	Top — a podium, tallest in the middle. Reads as standings where a plain bar
	chart reads as statistics, which is what Upgrades already means.
]]
local function drawTop(parent: GuiObject, color: Color3, _hole: Color3)
	-- Anchored on the base line at y = 0.86 so the three bars sit on the floor.
	shape(parent, "Second", 0.18, 0.86 - 0.20, 0.26, 0.40, color, 0, 0.18)
	shape(parent, "First", 0.5, 0.86 - 0.31, 0.26, 0.62, color, 0, 0.18)
	shape(parent, "Third", 0.82, 0.86 - 0.14, 0.26, 0.28, color, 0, 0.18)
	shape(parent, "Base", 0.5, 0.9, 0.92, 0.1, color, 0, 0.4)
end

--[[
	Settings — sliders. Three rails with their knobs at different positions, which
	says "adjustable" at a size where a gear says nothing.
]]
local function drawSettings(parent: GuiObject, color: Color3, _hole: Color3)
	-- The handle is a short bar ACROSS its rail, not a circle on it. A round knob
	-- has to be told apart from the rail by colour, and at 28 pixels there is not
	-- enough of it left to tell — the two merge into a blob. A perpendicular tick
	-- is still a tick at any size, and needs no second colour to work.
	-- Rails are 0.24 apart, so a handle taller than about 0.22 reaches into the
	-- next one and the three merge into a single block at tile size.
	for index, spec in { { 0.26, 0.32 }, { 0.5, 0.7 }, { 0.74, 0.46 } } do
		local y, handleX = spec[1], spec[2]
		shape(parent, `Rail{index}`, 0.5, y, 0.88, 0.08, color, 0, 1)
		shape(parent, `Handle{index}`, handleX, y, 0.14, 0.2, color, 0, 0.4)
	end
end

--[[
	Train — a dumbbell: a bar with a plate stack at each end.

	Deliberately horizontal where Upgrades is vertical and Top is three uprights, so
	the three read apart in a row of 28-pixel tiles without relying on colour.
]]
local function drawTrain(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "Bar", 0.5, 0.5, 0.44, 0.12, color, 0, 1)
	for _, side in { -1, 1 } do
		-- Inner plate short, outer plate tall: the silhouette of a loaded bar, and it
		-- survives being drawn a third this size.
		shape(parent, `Inner{side}`, 0.5 + side * 0.28, 0.5, 0.11, 0.42, color, 0, 0.3)
		shape(parent, `Outer{side}`, 0.5 + side * 0.42, 0.5, 0.11, 0.66, color, 0, 0.3)
	end
end

--[[
	Info — a sheet with writing on it. Deliberately a portrait rectangle where Shop
	and Train are landscape, so the tab strip reads apart at a glance.
]]
local function drawInfo(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "Sheet", 0.5, 0.5, 0.66, 0.86, color, 0, 0.14)
	-- Three ruled lines knocked out of the page. The top one is short, which reads
	-- as a heading rather than as a fourth line of body text.
	for index, spec in { { 0.3, 0.26 }, { 0.5, 0.42 }, { 0.66, 0.42 } } do
		local y, width = spec[1], spec[2]
		knockout(parent, `Line{index}`, 0.5 - (0.42 - width) / 2, y, width, 0.07, hole, 0, 1)
	end
end

--[[
	The five stat glyphs communicate what a stat DOES, not an abstract anatomical
	shape. At 32–48 pixels the old pec slabs, lat V, abs grid and trouser-like legs
	needed their labels to be understood. These use familiar objects with five clearly
	different outer silhouettes: glove, heart, shield, target and speed arrow.
]]

-- Arms — a forward punching glove with four visible knuckles and a thumb.
local function drawFist(parent: GuiObject, color: Color3, _hole: Color3)
	for index, x in { 0.23, 0.41, 0.59, 0.77 } do
		shape(parent, `Knuckle{index}`, x, 0.29, 0.21, 0.27, color, 0, 1)
	end
	shape(parent, "Palm", 0.5, 0.52, 0.72, 0.44, color, 0, 0.32)
	shape(parent, "Thumb", 0.22, 0.58, 0.22, 0.34, color, -34, 0.5)
	shape(parent, "Wrist", 0.53, 0.82, 0.44, 0.22, color, 0, 0.24)
end

-- Chest — health. A heart with a medical cutout is clearer than two floating pecs.
local function drawChest(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "HeartLeft", 0.34, 0.34, 0.43, 0.43, color, 0, 1)
	shape(parent, "HeartRight", 0.66, 0.34, 0.43, 0.43, color, 0, 1)
	shape(parent, "HeartPoint", 0.5, 0.58, 0.58, 0.58, color, 45, 0.12)
	knockout(parent, "HealthVertical", 0.5, 0.47, 0.1, 0.3, hole, 0, 0.25)
	knockout(parent, "HealthHorizontal", 0.5, 0.47, 0.3, 0.1, hole, 0, 0.25)
end

-- Back — durability. A broad shield survives scaling without anatomical detail.
local function drawBack(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "ShieldHead", 0.5, 0.4, 0.76, 0.62, color, 0, 0.28)
	shape(parent, "ShieldPoint", 0.5, 0.66, 0.54, 0.54, color, 45, 0.12)
	-- A single inset brace keeps the shield from becoming a featureless blob.
	knockout(parent, "ShieldInset", 0.5, 0.45, 0.34, 0.38, hole, 0, 0.3)
	shape(parent, "ShieldCore", 0.5, 0.47, 0.17, 0.31, color, 0, 0.3)
end

-- Core — the centre of the body and the source of reflected force: a bullseye.
local function drawCore(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "OuterRing", 0.5, 0.5, 0.86, 0.86, color, 0, 1)
	knockout(parent, "RingGap", 0.5, 0.5, 0.56, 0.56, hole, 0, 1)
	shape(parent, "Centre", 0.5, 0.5, 0.28, 0.28, color, 0, 1)
end

-- Legs — movement speed. A forward arrow with motion rails stays clear at any size.
local function drawLegs(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "TrailTop", 0.18, 0.32, 0.27, 0.09, color, 0, 1)
	shape(parent, "TrailMiddle", 0.14, 0.5, 0.2, 0.09, color, 0, 1)
	shape(parent, "TrailBottom", 0.18, 0.68, 0.27, 0.09, color, 0, 1)
	shape(parent, "ArrowShaft", 0.55, 0.5, 0.62, 0.17, color, 0, 1)
	shape(parent, "ArrowTop", 0.76, 0.37, 0.4, 0.17, color, 45, 1)
	shape(parent, "ArrowBottom", 0.76, 0.63, 0.4, 0.17, color, -45, 1)
end

--[[
	Arrow — where the player is facing, for the minimap.

	A solid delta rather than the open chevron Upgrades uses: on the minimap this sits on
	top of a busy map of streets and buildings, and an outline disappears into them where
	a filled shape does not.
]]
local function drawArrow(parent: GuiObject, color: Color3, _hole: Color3)
	-- Two fat blades meeting at the top and a stem under them. Fatter than the chevron
	-- Upgrades draws, because that one sits alone on a dark tile while this one has a
	-- city under it and a thin line disappears into a street.
	shape(parent, "BladeLeft", 0.33, 0.36, 0.2, 0.54, color, -38, 0.5)
	shape(parent, "BladeRight", 0.67, 0.36, 0.2, 0.54, color, 38, 0.5)
	shape(parent, "Stem", 0.5, 0.58, 0.22, 0.6, color, 0, 0.45)
end

--[[
	Close — the cross on every panel's corner.

	This one is here because the typed version was broken in a way nobody could see
	from the code: the buttons carried the text `✕` (U+2715), and Roblox's Gotham faces
	do not have that character, so every close control in the game rendered as an empty
	box. The `×` those same panels use for multipliers is a different character from
	Latin-1, which is why only this one was affected and why the bug survived so long.

	Drawn from two Frames, it cannot go missing on a font that lacks a glyph, and it
	scales with its tile like everything else here.
]]
local function drawClose(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "BarA", 0.5, 0.5, 0.74, 0.15, color, 45, 0.5)
	shape(parent, "BarB", 0.5, 0.5, 0.74, 0.15, color, -45, 0.5)
end

--[[
	Plus and Minus — the map's zoom controls.

	Typed, these were `+` and `−`, and the second one is U+2212, which Gotham does not
	have. It had been rendering as a box for as long as it existed and nobody could
	report it, because the muscle filter bar was drawn on top of both buttons.
]]
local function drawMinus(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "Bar", 0.5, 0.5, 0.66, 0.15, color, 0, 0.5)
end

local function drawPlus(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "BarH", 0.5, 0.5, 0.66, 0.15, color, 0, 0.5)
	shape(parent, "BarV", 0.5, 0.5, 0.15, 0.66, color, 0, 0.5)
end

--[[
	Recenter — put the map back where it started.

	A viewfinder: a frame with a dot in the middle. Not the map pin, even though one
	already exists and would have been free — a pin on a reset button reads as "go
	somewhere", which is the opposite of what this does.
]]
local function drawRecenter(parent: GuiObject, color: Color3, hole: Color3)
	local frame = shape(parent, "Frame", 0.5, 0.5, 0.76, 0.66, color, 0, 0.16)
	knockout(frame, "Window", 0.5, 0.5, 0.76, 0.7, hole, 0, 0.14)
	shape(parent, "Centre", 0.5, 0.5, 0.2, 0.2, color, 0, 1)
end

--[[
	Potion — a flask: narrow neck, round body. Reads as "drink this" without needing
	the bubbles that vanish at tile size.
]]
local function drawPotion(parent: GuiObject, color: Color3, _hole: Color3)
	shape(parent, "Cork", 0.5, 0.14, 0.2, 0.16, color, 0, 0.3)
	shape(parent, "Neck", 0.5, 0.32, 0.14, 0.24, color, 0, 0.2)
	shape(parent, "Body", 0.5, 0.68, 0.66, 0.5, color, 0, 0.42)
end

--[[
	Vip — a crown. Three peaks on a band; the notches are knocked out so the whole
	glyph stays a single silhouette at size.
]]
local function drawVip(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "Band", 0.5, 0.74, 0.86, 0.2, color, 0, 0.16)
	shape(parent, "Peaks", 0.5, 0.44, 0.86, 0.42, color, 0, 0.1)
	for _, x in { 0.32, 0.68 } do
		knockout(parent, `Notch{x}`, x, 0.34, 0.14, 0.3, hole, 0, 0.3)
	end
end

--[[
	Quest — a checklist: a board with a tick. The tick is two bars at opposing
	angles, which is the only way to draw one out of rectangles.
]]
local function drawQuest(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "Board", 0.5, 0.52, 0.78, 0.84, color, 0, 0.14)
	knockout(parent, "TickShort", 0.38, 0.58, 0.1, 0.26, hole, 45, 1)
	knockout(parent, "TickLong", 0.56, 0.48, 0.1, 0.46, hole, -40, 1)
end

--[[
	Goblin — a head with pointed ears and two knocked-out eyes.

	Everything here is chosen to survive being 28 pixels wide on a map. The ears are
	rotated squares rather than real triangles, because at that size a triangle and a
	tilted square are the same picture and one of them is a single frame. The eyes are
	knockouts rather than dark shapes so the glyph reads on a light paper map and on a
	dark HUD tile without being redrawn.
]]
local function drawGoblin(parent: GuiObject, color: Color3, hole: Color3)
	-- Ears first, so the head overlaps their inner corners and they read as attached.
	shape(parent, "EarLeft", 0.16, 0.38, 0.26, 0.26, color, 45, 0.12)
	shape(parent, "EarRight", 0.84, 0.38, 0.26, 0.26, color, 45, 0.12)

	local head = shape(parent, "Head", 0.5, 0.5, 0.62, 0.58, color, 0, 0.32)
	knockout(head, "EyeLeft", 0.32, 0.4, 0.18, 0.22, hole, 0, 1)
	knockout(head, "EyeRight", 0.68, 0.4, 0.18, 0.22, hole, 0, 1)
	-- One wide gap for the mouth. A row of separate teeth vanishes at map size.
	knockout(head, "Mouth", 0.5, 0.74, 0.44, 0.1, hole, 0, 0.4)
end

--[[
	Boss goblin — the same head, horned.

	Deliberately built from the goblin rather than beside it: the two icons have to be
	recognisably the same creature, or the map stops saying "this is the big one" and
	starts saying "this is something else".
]]
local function drawGoblinBoss(parent: GuiObject, color: Color3, hole: Color3)
	shape(parent, "HornLeft", 0.22, 0.14, 0.16, 0.3, color, 20, 0.3)
	shape(parent, "HornRight", 0.78, 0.14, 0.16, 0.3, color, -20, 0.3)
	drawGoblin(parent, color, hole)
end

local ICONS: { [string]: Builder } = {
	Map = drawMap,
	Train = drawTrain,
	Upgrades = drawUpgrades,
	Shop = drawShop,
	Top = drawTop,
	Settings = drawSettings,
	Info = drawInfo,
	Fist = drawFist,
	Chest = drawChest,
	Back = drawBack,
	Core = drawCore,
	Legs = drawLegs,
	Arrow = drawArrow,
	Close = drawClose,
	Plus = drawPlus,
	Minus = drawMinus,
	Recenter = drawRecenter,
	Potion = drawPotion,
	Vip = drawVip,
	Quest = drawQuest,
	Goblin = drawGoblin,
	GoblinBoss = drawGoblinBoss,
	-- The dumbbell is the token mark throughout the HUD, and Train already is one.
	-- Aliased rather than copied so the two cannot drift apart in a restyle.
	Token = drawTrain,
	-- Rank is the podium. Same glyph as the leaderboard tab because they are the
	-- same idea seen from two places.
	Rank = drawTop,
}

function Icons.Has(name: string): boolean
	return ICONS[name] ~= nil
end

--[[
	Draws a named glyph into a square container filling `parent`.

	`hole` is the colour punched out of a shape — the tile the icon sits on. It is
	passed in rather than read from the palette because the same icon is drawn on a
	dark tile and again on an accent-filled one when its screen is open, and a
	knockout that ignores what is behind it stops being a knockout.

	An unknown name draws a dot and warns rather than leaving an empty tile: a
	button with no picture is a bug you find in a screenshot, and a button with a
	placeholder is one you find in the output window.
]]
function Icons.Draw(name: string, parent: GuiObject, color: Color3, hole: Color3): Frame
	local holder = Instance.new("Frame")
	holder.Name = `Icon_{name}`
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	-- Square whatever the tile does, so nothing skews on an odd aspect.
	UI.AspectRatio(holder, 1)
	holder.Parent = parent

	local builder = ICONS[name]
	if builder == nil then
		warn(`[Icons] No icon named "{name}"`)
		shape(holder, "Unknown", 0.5, 0.5, 0.42, 0.42, color, 0, 1)
		return holder
	end

	builder(holder, color, hole)
	return holder
end

export type CloseOptions = {
	-- Side of the square button in pixels.
	Size: number?,
	-- The page this closes.
	OnActivated: (() -> ())?,
	-- Fires on the way down, for the click sound. Icons is a shared module and cannot
	-- reach EffectsController, so the caller hands it in like every other Pressable.
	OnPress: (() -> ())?,
}

--[[
	The close button every page corner gets.

	It lives in Icons rather than UI because the dependency only runs one way: UI
	requires nothing at all and this file requires UI, so a `UI.CloseButton` that drew a
	glyph would close the loop and fail at load. The button is the glyph plus the chrome
	that makes it pressable, so this is the end of the arrow it belongs on.

	The cross is hardcoded white rather than given an Ink role, which matters more than
	it looks: `OnAccent` is the obvious choice and is cream in the light palette and
	near-black in the dark one, so a themed page would turn the cross black on red. It
	sits on a red fill in both palettes, so it is white in both.
]]
function Icons.CloseButton(parent: Instance, options: CloseOptions?): TextButton
	-- Annotated, not inferred, for the reason UI.Pressable records: `options or {}`
	-- widens to `CloseOptions | {}` and every field read below fails on the empty half.
	local settings: CloseOptions = options or {}
	local side = settings.Size or 32

	local button = Instance.new("TextButton")
	button.Name = "Close"
	button.Size = UDim2.fromOffset(side, side)
	button.BackgroundColor3 = UI.Palette.Danger
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Text = ""
	UI.Role(button, { Fill = "Danger" })

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	-- The glyph sits inside the circle rather than filling it, or the bars run off the
	-- curve at the corners.
	local holder = Instance.new("Frame")
	holder.Name = "Glyph"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(0.52, 0.52)
	holder.BackgroundTransparency = 1
	holder.Parent = button

	local white = Color3.new(1, 1, 1)
	Icons.Draw("Close", holder, white, white)

	button.Parent = parent

	UI.Pressable(button, {
		PressScale = 0.9,
		HoverScale = 1.08,
		OnPress = settings.OnPress,
	})

	local activated = settings.OnActivated
	if activated ~= nil then
		button.Activated:Connect(activated)
	end

	return button
end

--[[
	Recolours an already-drawn glyph in place, so a tile can change state without
	tearing its icon down and rebuilding it every time the menu opens.
]]
function Icons.Recolour(holder: Frame, color: Color3, hole: Color3)
	for _, child in holder:GetDescendants() do
		if not child:IsA("Frame") then
			continue
		end
		-- Knockouts are the parts drawn in the tile's own colour; everything else
		-- is the glyph. They say so themselves, so this never has to know how any
		-- individual icon is put together.
		child.BackgroundColor3 = if child:GetAttribute("Knockout") == true then hole else color
	end
end

--[[
	Motion.

	The shared Info/dock symbols move according to their meaning: the glove jabs, health
	and defence pulse, the target tightens, and the speed arrow drives forward.

	The animation lives here rather than in the HUD for the reason the drawing does: only
	this file knows that Chest is made of heart parts or Legs is made of an arrow. A new glyph
	brings its own motion in the same edit, and nothing downstream branches on a stat id.

	Each animator is written against a small rig — Move, Grow, Turn — which records the
	part's resting value before touching it, so stopping restores the glyph exactly
	rather than approximately. Amplitudes are all multiplied by `strength`, which is how
	an idling slot and the slot actually being trained share one definition.
]]

local TweenService = game:GetService("TweenService")

export type Rig = {
	-- Slide a part, in the glyph's own 0..1 space.
	Move: (name: string, dx: number, dy: number) -> (),
	-- Stretch or squash it.
	Grow: (name: string, dw: number, dh: number) -> (),
	-- Swing it, in degrees, on top of whatever rotation it was drawn with.
	Turn: (name: string, degrees: number) -> (),
}

export type Animator = (rig: Rig) -> ()

--[[
	Fist — a jab. Drives up and forward, which on a flat glyph is up and slightly out.
]]
local function animateFist(rig: Rig)
	for index = 1, 4 do
		rig.Move(`Knuckle{index}`, 0.03, -0.07)
	end
	rig.Move("Palm", 0.03, -0.07)
	rig.Move("Thumb", 0.03, -0.07)
	rig.Move("Wrist", 0.02, -0.05)
end

-- Chest — the health heart beats.
local function animateChest(rig: Rig)
	rig.Grow("HeartLeft", 0.04, 0.04)
	rig.Grow("HeartRight", 0.04, 0.04)
	rig.Grow("HeartPoint", 0.04, 0.04)
end

-- Back — the durability shield braces outward.
local function animateBack(rig: Rig)
	rig.Grow("ShieldHead", 0.04, 0.04)
	rig.Grow("ShieldPoint", 0.03, 0.03)
	rig.Grow("ShieldInset", 0.02, 0.02)
end

-- Core — the target tightens around its centre.
local function animateCore(rig: Rig)
	rig.Grow("OuterRing", 0.06, 0.06)
	rig.Grow("RingGap", 0.04, 0.04)
	rig.Grow("Centre", 0.02, 0.02)
end

-- Legs — the speed arrow surges forward while its trails stay planted.
local function animateLegs(rig: Rig)
	rig.Move("ArrowShaft", 0.05, 0)
	rig.Move("ArrowTop", 0.05, 0)
	rig.Move("ArrowBottom", 0.05, 0)
end

local MOTIONS: { [string]: Animator } = {
	Fist = animateFist,
	Chest = animateChest,
	Back = animateBack,
	Core = animateCore,
	Legs = animateLegs,
}

-- Slow, because these run under the player's eyeline for the length of a session and
-- anything brisker becomes something to look away from. One full cycle is out and back.
local MOTION_SECONDS = 1.15

--[[
	Starts a glyph moving and returns the function that stops it.

	`delay` staggers a row of glyphs so five of them do not breathe in unison, which
	reads as the whole bar throbbing rather than as five muscles working.

	A glyph with no motion of its own gets a gentle overall swell instead of nothing, so
	a sixth stat is never the one dead tile in the row.
]]
function Icons.Animate(holder: Frame, name: string, strength: number?, delay: number?): () -> ()
	local amount = strength or 1
	local info =
		TweenInfo.new(MOTION_SECONDS, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, delay or 0)

	local tweens: { Tween } = {}
	-- What each part looked like before this touched it, so stopping is exact.
	local resting: { { instance: Instance, property: string, value: any } } = {}

	local function drive(partName: string, property: string, goal: any)
		local part = holder:FindFirstChild(partName, true)
		if part == nil or not part:IsA("Frame") then
			return
		end
		table.insert(
			resting,
			{ instance = part :: Instance, property = property, value = (part :: any)[property] }
		)
		local tween = TweenService:Create(part, info, { [property] = goal })
		table.insert(tweens, tween)
		tween:Play()
	end

	local animator = MOTIONS[name]
	if animator ~= nil then
		local rig: Rig = {
			Move = function(partName, dx, dy)
				local part = holder:FindFirstChild(partName, true)
				if part ~= nil and part:IsA("Frame") then
					drive(partName, "Position", part.Position + UDim2.fromScale(dx * amount, dy * amount))
				end
			end,
			Grow = function(partName, dw, dh)
				local part = holder:FindFirstChild(partName, true)
				if part ~= nil and part:IsA("Frame") then
					drive(partName, "Size", part.Size + UDim2.fromScale(dw * amount, dh * amount))
				end
			end,
			Turn = function(partName, degrees)
				local part = holder:FindFirstChild(partName, true)
				if part ~= nil and part:IsA("Frame") then
					drive(partName, "Rotation", part.Rotation + degrees * amount)
				end
			end,
		}
		animator(rig)
	else
		-- The fallback swells the whole glyph. It uses the holder's own UIScale, which
		-- is the one thing UI.Pop also drives — but only glyphs with no motion of their
		-- own ever reach here, and a stat with a picture has a motion.
		local existing = holder:FindFirstChildOfClass("UIScale")
		local live: UIScale
		if existing ~= nil then
			live = existing
		else
			live = Instance.new("UIScale")
			live.Parent = holder
		end
		table.insert(resting, { instance = live :: Instance, property = "Scale", value = live.Scale })
		local tween = TweenService:Create(live, info, { Scale = 1 + 0.09 * amount })
		table.insert(tweens, tween)
		tween:Play()
	end

	return function()
		for _, tween in tweens do
			tween:Cancel()
		end
		for _, entry in resting do
			if entry.instance.Parent ~= nil then
				(entry.instance :: any)[entry.property] = entry.value
			end
		end
	end
end

return Icons
