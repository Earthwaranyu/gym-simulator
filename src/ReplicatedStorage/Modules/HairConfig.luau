--!strict
--[[
	HairConfig — hairstyles as primitives, not as accessories.

	The project's asset rule allows nothing anyone else drew, which rules out every
	hair accessory on the platform. So a style is a handful of blocks, balls and wedges
	welded to the head, described here and built by AppearanceController — the same
	technique MobRigConfig uses to make a goblin out of parts.

	**Offsets and sizes are fractions of the head part, not studs.** The body grows: a
	trained player's head is bigger than a newbie's, and BodyMeshController rescales the
	rig continuously. Anything measured in absolute studs would sink into the skull on
	one player and hover over it on another. Multiplying by `Head.Size` at build time
	means a style fits every head this game will ever produce, including ones the
	muscle system has not invented yet.

	Colour is a lerp toward black or white from the style's own base, so a style is one
	colour with shading rather than a paint chart — same `Shade` convention as
	MobRigConfig.

	`None` is a real style, first in the list. A player who wants a bald bruiser should
	not have to hunt for the absence of a choice.

	**Nothing may hang below y = 0.2 across the front of the head.** The eyes sit around
	y = 0.08 and the brows at 0.2, so a cap that is merely head-sized and nudged upward
	reads as a motorcycle helmet with a chin showing — it swallows the forehead and the
	eyes both. Lift and height, not width, are what make a style read as hair.
]]

local HairConfig = {}

export type Shape = "Block" | "Ball" | "Wedge"

export type Piece = {
	Shape: Shape,
	-- Multiplied by Head.Size.
	Size: Vector3,
	-- Multiplied by Head.Size, from the head's centre.
	Offset: Vector3,
	-- Degrees, applied in the head's own space.
	Rotation: Vector3?,
	-- Toward black below zero, toward white above it, from the style's Color.
	Shade: number?,
}

export type Style = {
	Id: string,
	DisplayName: string,
	Color: Color3,
	Pieces: { Piece },
}

local BLACK = Color3.fromRGB(28, 26, 30)

HairConfig.Styles = {
	{
		Id = "None",
		DisplayName = "Shaved",
		Color = BLACK,
		Pieces = {},
	},
	{
		Id = "Buzz",
		DisplayName = "Buzz Cut",
		Color = BLACK,
		Pieces = {
			-- One shallow cap. A buzz cut is a shadow on the scalp, so it barely
			-- stands off the head at all.
			{ Shape = "Ball", Size = Vector3.new(1.02, 0.62, 1.02), Offset = Vector3.new(0, 0.4, 0) },
		},
	},
	{
		Id = "Flattop",
		DisplayName = "Flat Top",
		Color = BLACK,
		Pieces = {
			{ Shape = "Block", Size = Vector3.new(1.0, 0.4, 1.0), Offset = Vector3.new(0, 0.58, 0) },
			{
				Shape = "Block",
				Size = Vector3.new(1.02, 0.22, 1.02),
				Offset = Vector3.new(0, 0.38, 0),
				Shade = -0.2,
			},
		},
	},
	{
		Id = "Messy",
		DisplayName = "Messy",
		Color = BLACK,
		Pieces = {
			{ Shape = "Ball", Size = Vector3.new(1.12, 0.72, 1.1), Offset = Vector3.new(0, 0.44, 0) },
			-- The fringe. Pushed forward and tilted so it breaks the brow line, which
			-- is what separates "messy" from "helmet".
			{
				Shape = "Wedge",
				Size = Vector3.new(0.86, 0.3, 0.4),
				Offset = Vector3.new(0, 0.36, -0.46),
				Rotation = Vector3.new(-16, 0, 0),
			},
			{
				Shape = "Block",
				Size = Vector3.new(0.28, 0.5, 0.28),
				Offset = Vector3.new(-0.3, 0.6, -0.1),
				Rotation = Vector3.new(0, 0, 24),
				Shade = 0.08,
			},
			{
				Shape = "Block",
				Size = Vector3.new(0.24, 0.44, 0.24),
				Offset = Vector3.new(0.32, 0.58, 0.14),
				Rotation = Vector3.new(0, 0, -18),
				Shade = 0.08,
			},
		},
	},
	{
		Id = "Ponytail",
		DisplayName = "Ponytail",
		Color = BLACK,
		Pieces = {
			{ Shape = "Ball", Size = Vector3.new(1.08, 0.7, 1.06), Offset = Vector3.new(0, 0.44, 0) },
			{ Shape = "Block", Size = Vector3.new(0.34, 0.72, 0.34), Offset = Vector3.new(0, 0.3, 0.58) },
			{
				Shape = "Block",
				Size = Vector3.new(0.26, 0.5, 0.26),
				Offset = Vector3.new(0, -0.12, 0.72),
				Rotation = Vector3.new(18, 0, 0),
				Shade = -0.15,
			},
		},
	},
	{
		Id = "Mohawk",
		DisplayName = "Mohawk",
		Color = BLACK,
		Pieces = {
			{
				Shape = "Block",
				Size = Vector3.new(0.98, 0.14, 0.98),
				Offset = Vector3.new(0, 0.44, 0),
				Shade = -0.3,
			},
			{ Shape = "Block", Size = Vector3.new(0.22, 0.56, 0.98), Offset = Vector3.new(0, 0.74, 0) },
			{
				Shape = "Wedge",
				Size = Vector3.new(0.22, 0.3, 0.34),
				Offset = Vector3.new(0, 0.76, -0.5),
				Rotation = Vector3.new(0, 180, 0),
			},
		},
	},
	{
		Id = "Afro",
		DisplayName = "Afro",
		Color = BLACK,
		Pieces = {
			{ Shape = "Ball", Size = Vector3.new(1.46, 1.02, 1.44), Offset = Vector3.new(0, 0.58, 0.06) },
			{
				Shape = "Ball",
				Size = Vector3.new(0.86, 0.72, 0.86),
				Offset = Vector3.new(-0.46, 0.4, 0.2),
				Shade = 0.06,
			},
			{
				Shape = "Ball",
				Size = Vector3.new(0.86, 0.72, 0.86),
				Offset = Vector3.new(0.46, 0.42, 0.16),
				Shade = 0.06,
			},
		},
	},
	{
		Id = "Locs",
		DisplayName = "Locs",
		Color = BLACK,
		Pieces = {
			{ Shape = "Ball", Size = Vector3.new(1.1, 0.72, 1.08), Offset = Vector3.new(0, 0.44, 0) },
			{
				Shape = "Block",
				Size = Vector3.new(0.18, 0.86, 0.18),
				Offset = Vector3.new(-0.44, 0.02, 0.36),
			},
			{
				Shape = "Block",
				Size = Vector3.new(0.18, 0.94, 0.18),
				Offset = Vector3.new(0, -0.02, 0.5),
				Shade = -0.1,
			},
			{ Shape = "Block", Size = Vector3.new(0.18, 0.86, 0.18), Offset = Vector3.new(0.44, 0.02, 0.36) },
			{
				Shape = "Block",
				Size = Vector3.new(0.18, 0.66, 0.18),
				Offset = Vector3.new(-0.5, 0.1, -0.16),
				Shade = 0.06,
			},
			{
				Shape = "Block",
				Size = Vector3.new(0.18, 0.66, 0.18),
				Offset = Vector3.new(0.5, 0.1, -0.16),
				Shade = 0.06,
			},
		},
	},
} :: { Style }

function HairConfig.Get(id: string?): Style
	if id ~= nil then
		for _, style in HairConfig.Styles do
			if style.Id == id then
				return style
			end
		end
	end
	return HairConfig.Styles[1]
end

function HairConfig.IsValid(id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	for _, style in HairConfig.Styles do
		if style.Id == id then
			return true
		end
	end
	return false
end

return HairConfig
