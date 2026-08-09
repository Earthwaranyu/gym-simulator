--!strict
--[[
	MapRender — the shared parts of drawing the world as a picture.

	Two surfaces draw the same city: the full Map screen in MenuController, and the
	minimap in the corner of the HUD. Before this module the full map owned all of it —
	the server round-trip, the bounds maths, the feature Frames — and a minimap could
	only have been a copy of six hundred lines that would drift the first time a new
	feature kind was added.

	So the parts that are the same on both are here, and the parts that differ stay with
	their screen. What differs is not the drawing, it is the framing:

	  * The full map fits the whole world into a fixed board, so it letterboxes its
	    bounds to a chosen aspect ratio and pans within them.
	  * The minimap keeps the player at the centre at a fixed studs-per-pixel, so it
	    takes the raw bounds and slides an oversized canvas underneath a small window.

	`Bounds` therefore takes the aspect as an optional argument: pass one to letterbox,
	pass nothing to get the world's own shape.

	Everything drawn here is Frames — no image, no asset id — which is the same rule the
	rest of the interface follows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)

local MapRender = {}

export type Destination = {
	Id: string,
	ZoneId: string,
	EquipmentId: string,
	StatId: string,
	RequiredPower: number,
	GainMultiplier: number,
	Position: Vector3,
	AccessKind: string,
	FloorIndex: number,
	EnvironmentId: string,
	VariantId: string,
	ExerciseFamily: string,
	RequiresFlight: boolean,
	LocationName: string,
	LocationTagline: string,
}

export type Feature = {
	Kind: string,
	Shape: string,
	X: number,
	Z: number,
	Width: number,
	Depth: number,
	Rotation: number,
	Color: Color3,
}

export type Bounds = {
	MinX: number,
	MinZ: number,
	Width: number,
	Depth: number,
}

-- The map is the one surface that is NOT dark.
--
-- The rest of the UI is a dark HUD over a bright world, which is right for something
-- you read at a glance. A map is the opposite job: you study it, and every feature on
-- it is a shade of the city's own concrete and asphalt — dark grey shapes on a dark
-- grey board, which is unreadable no matter how carefully the greys are chosen.
-- Lifting the whole thing to paper gives every feature somewhere to contrast against.
MapRender.Paper = Color3.fromRGB(232, 234, 238)
MapRender.Ink = Color3.fromRGB(38, 42, 52)
-- How far each feature's real colour is pulled toward white. High, because the source
-- colours are city-dark; the tint that survives is enough to tell water from park.
MapRender.WashAmount = 0.62

-- Buildings stay closest to their real colour so streets read as the gaps between them.
local BUILDING_WASH = 0.45

local FEATURE_LAYERS: { [string]: number } = {
	Water = 1,
	Land = 2,
	Block = 3,
	Park = 4,
	Road = 5,
	Building = 6,
	SkyPlatform = 7,
	Plaza = 8,
	SafeZone = 9,
}

local destinations: { Destination } = {}
local destinationsById: { [string]: Destination } = {}
local features: { Feature } = {}
local loaded = false

--[[
	Lightens a world colour into something readable on paper, keeping its hue so the
	map still reads as the city rather than as an abstract diagram.
]]
function MapRender.Tint(color: Color3, amount: number?): Color3
	return color:Lerp(Color3.new(1, 1, 1), amount or MapRender.WashAmount)
end

--[[
	Pulls every map-enabled training station and every world footprint from the server.

	Memoised, and deliberately so: StreamingEnabled means most stations do not exist in
	the client's Workspace, so this round-trip is the only way to know the world's shape
	— and the minimap opens on spawn while the map screen opens later, which without the
	cache would be two identical invokes of a server function that walks the whole city.

	Every field is checked before it is trusted. A malformed entry is skipped rather
	than allowed to poison the bounds, where one bad coordinate would squash the entire
	map into a corner.
]]
function MapRender.Fetch(): ({ Destination }, { Feature })
	if loaded then
		return destinations, features
	end

	local ok, list, rawFeatures = pcall(function()
		return Net.Function("GetDestinations"):InvokeServer()
	end)
	if not ok or type(list) ~= "table" then
		return destinations, features
	end

	table.clear(destinations)
	table.clear(destinationsById)
	table.clear(features)

	for _, entry in list do
		if
			type(entry) ~= "table"
			or type(entry.Id) ~= "string"
			or type(entry.ZoneId) ~= "string"
			or type(entry.EquipmentId) ~= "string"
			or type(entry.StatId) ~= "string"
			or type(entry.RequiredPower) ~= "number"
			or type(entry.GainMultiplier) ~= "number"
			or type(entry.X) ~= "number"
			or type(entry.Y) ~= "number"
			or type(entry.Z) ~= "number"
		then
			continue
		end
		local destination: Destination = {
			Id = entry.Id,
			ZoneId = entry.ZoneId,
			EquipmentId = entry.EquipmentId,
			StatId = entry.StatId,
			RequiredPower = entry.RequiredPower,
			GainMultiplier = entry.GainMultiplier,
			Position = Vector3.new(entry.X, entry.Y, entry.Z),
			AccessKind = if type(entry.AccessKind) == "string" then entry.AccessKind else "Street",
			FloorIndex = if type(entry.FloorIndex) == "number" then entry.FloorIndex else 1,
			EnvironmentId = if type(entry.EnvironmentId) == "string" then entry.EnvironmentId else "Unknown",
			VariantId = if type(entry.VariantId) == "string" then entry.VariantId else entry.EquipmentId,
			ExerciseFamily = if type(entry.ExerciseFamily) == "string"
				then entry.ExerciseFamily
				else entry.StatId,
			RequiresFlight = entry.RequiresFlight == true,
			LocationName = if type(entry.LocationName) == "string" then entry.LocationName else entry.ZoneId,
			LocationTagline = if type(entry.LocationTagline) == "string" then entry.LocationTagline else "",
		}
		table.insert(destinations, destination)
		destinationsById[destination.Id] = destination
	end

	if type(rawFeatures) == "table" then
		for _, entry in rawFeatures do
			if
				type(entry) ~= "table"
				or type(entry.Kind) ~= "string"
				or type(entry.Shape) ~= "string"
				or type(entry.X) ~= "number"
				or type(entry.Z) ~= "number"
				or type(entry.Width) ~= "number"
				or type(entry.Depth) ~= "number"
				or type(entry.Rotation) ~= "number"
				or typeof(entry.Color) ~= "Color3"
			then
				continue
			end
			table.insert(features, {
				Kind = entry.Kind,
				Shape = entry.Shape,
				X = entry.X,
				Z = entry.Z,
				Width = entry.Width,
				Depth = entry.Depth,
				Rotation = entry.Rotation,
				Color = entry.Color,
			})
		end
	end

	loaded = #destinations > 0
	return destinations, features
end

function MapRender.IsLoaded(): boolean
	return loaded
end

function MapRender.GetDestination(id: string): Destination?
	return destinationsById[id]
end

--[[
	The rectangle of world the picture covers.

	Bounds come from the generated walkable water and island footprints, not from the
	outermost pins, so the whole traversal field and its scattered islands stay in their
	true proportions. Destinations still take part, so a later offshore roof can never
	produce a pin outside the picture.

	`aspect` letterboxes the result to a width:depth ratio by growing the short side —
	never by cropping, because a cropped map loses an island. Omit it to get the world's
	own shape, which is what a follow-cam minimap wants.
]]
function MapRender.Bounds(
	worldFeatures: { Feature },
	worldDestinations: { Destination },
	aspect: number?
): Bounds
	local minX, maxX = math.huge, -math.huge
	local minZ, maxZ = math.huge, -math.huge

	local function include(feature: Feature)
		-- A rotated footprint's axis-aligned half-extents, so a diagonal island is not
		-- clipped by its own rotation.
		local angle = math.rad(feature.Rotation)
		local halfX = math.abs(math.cos(angle)) * feature.Width / 2
			+ math.abs(math.sin(angle)) * feature.Depth / 2
		local halfZ = math.abs(math.sin(angle)) * feature.Width / 2
			+ math.abs(math.cos(angle)) * feature.Depth / 2
		minX, maxX = math.min(minX, feature.X - halfX), math.max(maxX, feature.X + halfX)
		minZ, maxZ = math.min(minZ, feature.Z - halfZ), math.max(maxZ, feature.Z + halfZ)
	end

	local foundWorld = false
	for _, feature in worldFeatures do
		if feature.Kind == "Land" or feature.Kind == "Water" then
			include(feature)
			foundWorld = true
		end
	end
	if not foundWorld then
		for _, feature in worldFeatures do
			include(feature)
		end
	end

	for _, destination in worldDestinations do
		local at = destination.Position
		minX, maxX = math.min(minX, at.X - 12), math.max(maxX, at.X + 12)
		minZ, maxZ = math.min(minZ, at.Z - 12), math.max(maxZ, at.Z + 12)
	end

	-- Nothing to go on: a unit square, so callers divide by a real number and draw an
	-- empty picture rather than dividing by infinity and drawing NaNs.
	if minX > maxX or minZ > maxZ then
		return { MinX = 0, MinZ = 0, Width = 1, Depth = 1 }
	end

	local width = math.max(maxX - minX, 1)
	local depth = math.max(maxZ - minZ, 1)
	local pad = math.max(width, depth) * 0.025
	minX, maxX = minX - pad, maxX + pad
	minZ, maxZ = minZ - pad, maxZ + pad
	width, depth = maxX - minX, maxZ - minZ

	if aspect ~= nil and aspect > 0 then
		if width / depth > aspect then
			local extra = (width / aspect - depth) / 2
			minZ, maxZ = minZ - extra, maxZ + extra
		else
			local extra = (depth * aspect - width) / 2
			minX, maxX = minX - extra, maxX + extra
		end
		width, depth = maxX - minX, maxZ - minZ
	end

	return { MinX = minX, MinZ = minZ, Width = width, Depth = depth }
end

--[[
	A square of world centred on a point — what a follow-cam minimap actually needs.

	The minimap used to draw the entire city into one canvas thousands of pixels across
	and slide it under a small window. That works right up until the canvas is rotated,
	because Roblox will not reliably clip a rotated descendant, and an unclipped
	city-sized canvas is a slab of pale map painted over the whole screen. Drawing only
	the square the player can actually see bounds that failure to something the size of
	the panel, and it is a fraction of the Frames either way.
]]
function MapRender.BoundsAround(x: number, z: number, halfSize: number): Bounds
	local side = math.max(halfSize, 1) * 2
	return { MinX = x - side / 2, MinZ = z - side / 2, Width = side, Depth = side }
end

--[[
	The features whose footprint touches `bounds`, so a region canvas draws the dozens of
	shapes near the player rather than the hundreds in the city.
]]
function MapRender.FeaturesWithin(worldFeatures: { Feature }, bounds: Bounds): { Feature }
	local maxX, maxZ = bounds.MinX + bounds.Width, bounds.MinZ + bounds.Depth
	local near: { Feature } = {}

	for _, feature in worldFeatures do
		-- The same axis-aligned half-extents Bounds uses, so a rotated footprint that
		-- only just reaches into the square is still drawn rather than popping in later.
		local angle = math.rad(feature.Rotation)
		local halfX = math.abs(math.cos(angle)) * feature.Width / 2
			+ math.abs(math.sin(angle)) * feature.Depth / 2
		local halfZ = math.abs(math.sin(angle)) * feature.Width / 2
			+ math.abs(math.cos(angle)) * feature.Depth / 2
		if
			feature.X + halfX >= bounds.MinX
			and feature.X - halfX <= maxX
			and feature.Z + halfZ >= bounds.MinZ
			and feature.Z - halfZ <= maxZ
		then
			table.insert(near, feature)
		end
	end

	return near
end

--[[
	Turns world XZ into a position inside a canvas that fills the bounds.

	Always scale, never offset, so the same projection works for a 260-pixel minimap and
	a 1400-pixel map board without knowing the size of either.
]]
function MapRender.Project(bounds: Bounds): (number, number) -> UDim2
	return function(x: number, z: number): UDim2
		-- World +Z is north, and screen Y grows downward, so Z is flipped.
		return UDim2.fromScale((x - bounds.MinX) / bounds.Width, 1 - (z - bounds.MinZ) / bounds.Depth)
	end
end

--[[
	Draws every world footprint into `canvas`.

	`detail` false drops the strokes and corner rounding, which are invisible on a
	minimap and cost an instance each on a canvas that can hold hundreds of buildings.
]]
function MapRender.DrawFeatures(
	canvas: GuiObject,
	worldFeatures: { Feature },
	bounds: Bounds,
	detail: boolean?
)
	local project = MapRender.Project(bounds)
	local wantsDetail = detail ~= false

	for index, feature in worldFeatures do
		local shape = Instance.new("Frame")
		shape.Name = `Feature_{index}_{feature.Kind}`
		shape.AnchorPoint = Vector2.new(0.5, 0.5)
		shape.Position = project(feature.X, feature.Z)
		shape.Size = UDim2.fromScale(feature.Width / bounds.Width, feature.Depth / bounds.Depth)
		shape.Rotation = feature.Rotation
		shape.BackgroundColor3 =
			MapRender.Tint(feature.Color, if feature.Kind == "Building" then BUILDING_WASH else nil)
		shape.BackgroundTransparency = if feature.Kind == "SafeZone"
			then 0.45
			elseif feature.Kind == "Water" then 0.1
			elseif feature.Kind == "SkyPlatform" then 0.15
			else 0
		shape.BorderSizePixel = 0
		shape.ZIndex = FEATURE_LAYERS[feature.Kind] or 3
		shape.Parent = canvas

		if not wantsDetail then
			continue
		end

		if feature.Shape == "Circle" then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = shape
		elseif feature.Kind == "Building" or feature.Kind == "SafeZone" then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0, 2)
			corner.Parent = shape
		end

		if feature.Kind == "SafeZone" then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(0, 132, 178)
			stroke.Thickness = 2
			stroke.Parent = shape
		elseif feature.Kind == "SkyPlatform" then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Color3.fromRGB(96, 132, 168)
			stroke.Thickness = 1.5
			stroke.Parent = shape
		end
	end
end

--[[
	A round dot, which is what both surfaces use for "something is here".
]]
function MapRender.Dot(parent: GuiObject, name: string, size: number, color: Color3, zIndex: number): Frame
	local dot = Instance.new("Frame")
	dot.Name = name
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Size = UDim2.fromOffset(size, size)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.ZIndex = zIndex
	dot.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = dot

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI.Palette.Backdrop
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = dot

	return dot
end

return MapRender
