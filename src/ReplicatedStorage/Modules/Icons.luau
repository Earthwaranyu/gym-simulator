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
	Map — a marker diamond with the pin hole knocked out of it.
]]
local function drawMap(parent: GuiObject, color: Color3, hole: Color3)
	local body = shape(parent, "Diamond", 0.5, 0.46, 0.6, 0.6, color, 45, 0.16)
	-- Child of the diamond, so it turns with it and stays centred in the shape.
	shape(body, "Hole", 0.5, 0.5, 0.34, 0.34, hole, 0, 1)
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
	shape(body, "Fold", 0.5, 0.14, 1.0, 0.1, hole, 0, 0)

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

local ICONS: { [string]: Builder } = {
	Map = drawMap,
	Upgrades = drawUpgrades,
	Shop = drawShop,
	Top = drawTop,
	Settings = drawSettings,
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
		-- is the glyph. Distinguishing them by name keeps this from having to know
		-- how any individual icon is put together.
		local isHole = child.Name == "Hole" or child.Name == "Fold"
		child.BackgroundColor3 = if isHole then hole else color
	end
end

return Icons
