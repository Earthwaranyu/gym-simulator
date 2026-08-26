--!strict
--[[
	BodySkinPainter — draws the physique into a texture, in code, with no uploads.

	`BodySkinConfig` says what the muscles look like; this renders it. The result is a
	single `EditableImage` handed to the body mesh as `TextureContent`, which is the
	same mechanism the reference art uses: shadows painted onto a body, rather than
	shapes pushed out of one.

	Two things shape this file.

	**It bakes the base colour rather than relying on vertex tint.** The mesh could
	supply skin and shorts as vertex colours and let the texture carry only shading,
	which would need one texture for everybody. But whether Roblox multiplies a vertex
	colour into a MeshPart's texture or ignores it is not something this project can
	check right now — `screen_capture` is unavailable — and guessing wrong turns every
	player grey or white. Baking the colour in is correct under either behaviour, at
	the cost of one texture per palette.

	**Textures are cached globally, never per character.** A busy server has many
	players sharing a handful of skin tones, and a 512x512 fill is 14ms. Keyed by
	palette and crease stage, a server settles into a few textures no matter how many
	players arrive.
]]

local AssetService = game:GetService("AssetService")

local BodyLoftConfig = require(script.Parent.BodyLoftConfig)
local BodySkinConfig = require(script.Parent.BodySkinConfig)

local BodySkinPainter = {}

local RESOLUTION = BodySkinConfig.RESOLUTION
local cache: { [string]: EditableImage } = {}

export type Palette = { Skin: Color3, Pants: Color3 }

local function channel(value: number): number
	return math.clamp(math.floor(value * 255 + 0.5), 0, 255)
end

local function key(palette: Palette, stage: number): string
	return string.format(
		"%d.%d.%d|%d.%d.%d|%d",
		channel(palette.Skin.R),
		channel(palette.Skin.G),
		channel(palette.Skin.B),
		channel(palette.Pants.R),
		channel(palette.Pants.G),
		channel(palette.Pants.B),
		stage
	)
end

--[[
	Distance from a point to a line segment, in region space.

	Strokes are segments rather than curves because a curve costs a spline evaluation
	per pixel and reads no differently at this resolution — an ab separation is eleven
	pixels long. Where anatomy genuinely bends, BodySkinConfig uses two segments.
]]
local function distanceToSegment(
	px: number,
	py: number,
	ax: number,
	ay: number,
	bx: number,
	by: number
): number
	local dx, dy = bx - ax, by - ay
	local lengthSquared = dx * dx + dy * dy
	local t = 0
	if lengthSquared > 1e-12 then
		t = math.clamp(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0, 1)
	end
	local cx, cy = ax + dx * t, ay + dy * t
	local ox, oy = px - cx, py - cy
	return math.sqrt(ox * ox + oy * oy)
end

--[[
	Which rows of a tube's column are shorts rather than skin.

	Read off the tube's own rings rather than written down again here, so moving the
	hem in BodyLoftConfig moves the painted waistband with it.
]]
local function pantsRange(tube: any): (number, number)
	local first, last = nil, nil
	for index, ring in tube.Rings do
		if ring.Slot == "Pants" then
			first = first or index
			last = index
		end
	end
	if first == nil then
		return -1, -1
	end
	local count = #tube.Rings
	return (first - 1) / (count - 1), (last - 1) / (count - 1)
end

--[[
	Paints one texture for a palette and crease stage.

	Pixels are written straight into a buffer rather than through DrawLine, because a
	drawn line is hard-edged and a muscle shadow is not: the falloff across a stroke's
	width is most of what makes it read as a shadow instead of a scratch.
]]
local function paint(palette: Palette, stage: number, leanness: number): EditableImage?
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(RESOLUTION, RESOLUTION) })
	if image == nil then
		return nil
	end

	local progress = stage / BodySkinConfig.STAGES
	local pixels = buffer.create(RESOLUTION * RESOLUTION * 4)

	-- Base colours first: every column is skin, then the shorts band is laid over the
	-- rows the tube marks as Pants.
	local skinR, skinG, skinB = channel(palette.Skin.R), channel(palette.Skin.G), channel(palette.Skin.B)
	local pantsR, pantsG, pantsB =
		channel(palette.Pants.R), channel(palette.Pants.G), channel(palette.Pants.B)

	local columns: { { tube: any, x0: number, x1: number, v0: number, v1: number } } = {}
	for _, tube in BodyLoftConfig.TUBES do
		local v0, v1 = pantsRange(tube)
		table.insert(columns, {
			tube = tube,
			x0 = math.floor(tube.U0 * RESOLUTION),
			x1 = math.floor(tube.U1 * RESOLUTION) - 1,
			v0 = v0,
			v1 = v1,
		})
	end

	for y = 0, RESOLUTION - 1 do
		local v = y / (RESOLUTION - 1)
		local rowBase = y * RESOLUTION * 4
		for _, column in columns do
			local isPants = column.v0 >= 0 and v >= column.v0 and v <= column.v1
			local r = if isPants then pantsR else skinR
			local g = if isPants then pantsG else skinG
			local b = if isPants then pantsB else skinB
			for x = column.x0, column.x1 do
				local offset = rowBase + x * 4
				buffer.writeu8(pixels, offset, r)
				buffer.writeu8(pixels, offset + 1, g)
				buffer.writeu8(pixels, offset + 2, b)
				buffer.writeu8(pixels, offset + 3, 255)
			end
		end
	end

	-- Then the shadows, each confined to its own bounding box so the cost stays with
	-- the ink rather than with the canvas.
	local columnOf: { [string]: { x0: number, x1: number } } = {}
	for _, column in columns do
		columnOf[column.tube.Id] = { x0 = column.x0, x1 = column.x1 }
	end

	for _, s in BodySkinConfig.STROKES do
		local strength = BodySkinConfig.Strength(s, progress)
		if strength <= 0.01 then
			continue
		end
		local column = columnOf[s.Region]
		if column == nil then
			continue
		end
		local width = column.x1 - column.x0 + 1
		-- Leaner bodies cut harder. Capped short of 1 because Depth is a fraction
		-- toward black and a stroke that reaches it stops being a shadow and becomes a
		-- painted line; BodySkinConfig's self-test holds the authored values under 0.5
		-- for the same reason.
		local depth = math.min(s.Depth * leanness, 0.62) * strength
		-- The stroke's box, padded by its width and clamped to its own column so a
		-- torso shadow can never bleed onto the arm painted beside it.
		local pad = s.Width * 2
		local uMin = math.max(0, math.min(s.U0, s.U1) - pad)
		local uMax = math.min(1, math.max(s.U0, s.U1) + pad)
		local vMin = math.max(0, math.min(s.V0, s.V1) - pad)
		local vMax = math.min(1, math.max(s.V0, s.V1) + pad)
		local xStart = column.x0 + math.floor(uMin * width)
		local xEnd = column.x0 + math.ceil(uMax * width)
		local yStart = math.floor(vMin * (RESOLUTION - 1))
		local yEnd = math.ceil(vMax * (RESOLUTION - 1))

		for y = math.max(0, yStart), math.min(RESOLUTION - 1, yEnd) do
			local v = y / (RESOLUTION - 1)
			for x = math.max(column.x0, xStart), math.min(column.x1, xEnd) do
				local u = (x - column.x0) / math.max(1, width - 1)
				local distance = distanceToSegment(u, v, s.U0, s.V0, s.U1, s.V1)
				if distance < s.Width then
					-- Smoothstep falloff: hard in the middle, feathered at the edge.
					local t = 1 - distance / s.Width
					local fade = t * t * (3 - 2 * t)
					local factor = 1 - depth * fade
					local offset = y * RESOLUTION * 4 + x * 4
					buffer.writeu8(pixels, offset, channel(buffer.readu8(pixels, offset) / 255 * factor))
					buffer.writeu8(
						pixels,
						offset + 1,
						channel(buffer.readu8(pixels, offset + 1) / 255 * factor)
					)
					buffer.writeu8(
						pixels,
						offset + 2,
						channel(buffer.readu8(pixels, offset + 2) / 255 * factor)
					)
				end
			end
		end
	end

	image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	return image
end

--[[
	The texture for a palette at a progress, built once and shared.

	Returns nil when the EditableImage budget is exhausted; the caller carries on
	untextured rather than failing, because a plain-coloured body is a far better
	outcome than no body.
]]
--[[
	`leanness` is part of the cache key, not just an argument.

	The cache is shared across every body on the client, so a boss painted with deeper
	shadows would otherwise be handed to the next player who happens to share its skin
	tone — and that is the kind of wrong that never errors and never looks like a
	caching bug. Quantised for the same reason `progress` is: a continuous key would
	repaint a 512px texture for a difference nobody can see.
]]
function BodySkinPainter.Get(palette: Palette, progress: number, leanness: number?): EditableImage?
	local stage = math.floor(math.clamp(progress, 0, 1) * BodySkinConfig.STAGES + 0.5)
	local lean = BodyLoftConfig.Leanness(leanness)
	local leanStep = math.floor(lean * 10 + 0.5)
	local id = `{key(palette, stage)}|{leanStep}`
	local existing = cache[id]
	if existing then
		return existing
	end
	local image = paint(palette, stage, lean)
	if image ~= nil then
		cache[id] = image
	end
	return image
end

function BodySkinPainter.CacheSize(): number
	local count = 0
	for _ in cache do
		count += 1
	end
	return count
end

return BodySkinPainter
