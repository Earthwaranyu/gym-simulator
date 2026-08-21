--!strict
--[[
	FaceConfig — expressions drawn, not uploaded.

	A Roblox face is normally a Decal, which means an image asset, which the project's
	asset rule forbids unless we drew it. Rather than take on an art pipeline for four
	expressions, a face here is a short list of rectangles and ellipses that
	AppearanceController lays out on a SurfaceGui stuck to the front of the head. Frames
	with a UICorner are a perfectly good eye, and they cost nothing to author or change.

	Coordinates are **fractions of the head's front face**, with the origin at its
	centre: x runs -0.5 (the character's right, as seen from the front) to 0.5, y runs
	-0.5 (chin) to 0.5 (crown). Fractions rather than pixels for the same reason
	HairConfig uses them — the head changes size as the body grows, and a face pinned in
	pixels would slide off it.

	Every feature is opaque ink on skin. There is no white of the eye: at the distance
	players actually see each other, a solid shape reads and an eyeball does not.
]]

local FaceConfig = {}

export type Shape = "Rect" | "Ellipse"

export type Feature = {
	Shape: Shape,
	-- Centre of the feature, in head-face fractions from the middle of the face.
	Pos: Vector2,
	-- Width and height as fractions of the head's front face.
	Size: Vector2,
	-- Degrees, clockwise. This is what turns two identical bars into a scowl.
	Rotation: number?,
	Color: Color3?,
}

export type Face = {
	Id: string,
	DisplayName: string,
	Features: { Feature },
}

local INK = Color3.fromRGB(26, 24, 28)

FaceConfig.Faces = {
	{
		Id = "Neutral",
		DisplayName = "Neutral",
		Features = {
			{ Shape = "Ellipse", Pos = Vector2.new(-0.17, 0.08), Size = Vector2.new(0.12, 0.15) },
			{ Shape = "Ellipse", Pos = Vector2.new(0.17, 0.08), Size = Vector2.new(0.12, 0.15) },
			{ Shape = "Rect", Pos = Vector2.new(0, -0.2), Size = Vector2.new(0.22, 0.04) },
		},
	},
	{
		Id = "Smug",
		DisplayName = "Smug",
		Features = {
			-- Half-lidded: wide and short reads as a lowered lid where a circle reads
			-- as surprise.
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.08), Size = Vector2.new(0.14, 0.06) },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.08), Size = Vector2.new(0.14, 0.06) },
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.2), Size = Vector2.new(0.16, 0.04), Rotation = -10 },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.2), Size = Vector2.new(0.16, 0.04), Rotation = 10 },
			-- The smirk is one bar tilted off level. Symmetry would make it a smile.
			{
				Shape = "Rect",
				Pos = Vector2.new(0.04, -0.2),
				Size = Vector2.new(0.24, 0.045),
				Rotation = -12,
			},
		},
	},
	{
		Id = "Angry",
		DisplayName = "Angry",
		Features = {
			{ Shape = "Ellipse", Pos = Vector2.new(-0.17, 0.06), Size = Vector2.new(0.12, 0.13) },
			{ Shape = "Ellipse", Pos = Vector2.new(0.17, 0.06), Size = Vector2.new(0.12, 0.13) },
			-- Brows angled down toward the nose. This single pair of angles is doing
			-- all the work of the expression.
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.2), Size = Vector2.new(0.2, 0.05), Rotation = 22 },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.2), Size = Vector2.new(0.2, 0.05), Rotation = -22 },
			{ Shape = "Rect", Pos = Vector2.new(0, -0.2), Size = Vector2.new(0.26, 0.05), Rotation = 0 },
		},
	},
	{
		Id = "Focused",
		DisplayName = "Focused",
		Features = {
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.07), Size = Vector2.new(0.13, 0.05) },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.07), Size = Vector2.new(0.13, 0.05) },
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.19), Size = Vector2.new(0.18, 0.04), Rotation = 12 },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.19), Size = Vector2.new(0.18, 0.04), Rotation = -12 },
			-- Teeth gritted through a set.
			{ Shape = "Rect", Pos = Vector2.new(0, -0.21), Size = Vector2.new(0.3, 0.09) },
			{
				Shape = "Rect",
				Pos = Vector2.new(0, -0.21),
				Size = Vector2.new(0.3, 0.02),
				Color = Color3.fromRGB(226, 224, 218),
			},
		},
	},
	{
		Id = "Grin",
		DisplayName = "Grin",
		Features = {
			{ Shape = "Ellipse", Pos = Vector2.new(-0.17, 0.09), Size = Vector2.new(0.13, 0.16) },
			{ Shape = "Ellipse", Pos = Vector2.new(0.17, 0.09), Size = Vector2.new(0.13, 0.16) },
			{ Shape = "Ellipse", Pos = Vector2.new(0, -0.21), Size = Vector2.new(0.3, 0.16) },
			-- A pale bar across the mouth turns the hole into teeth.
			{
				Shape = "Rect",
				Pos = Vector2.new(0, -0.17),
				Size = Vector2.new(0.3, 0.05),
				Color = Color3.fromRGB(226, 224, 218),
			},
		},
	},
	{
		Id = "Tired",
		DisplayName = "Tired",
		Features = {
			{ Shape = "Rect", Pos = Vector2.new(-0.17, 0.07), Size = Vector2.new(0.14, 0.045) },
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.07), Size = Vector2.new(0.14, 0.045) },
			{
				Shape = "Rect",
				Pos = Vector2.new(-0.17, 0.19),
				Size = Vector2.new(0.16, 0.035),
				Rotation = -14,
			},
			{ Shape = "Rect", Pos = Vector2.new(0.17, 0.19), Size = Vector2.new(0.16, 0.035), Rotation = 14 },
			{ Shape = "Ellipse", Pos = Vector2.new(0, -0.21), Size = Vector2.new(0.14, 0.1) },
		},
	},
} :: { Face }

FaceConfig.Ink = INK

function FaceConfig.Get(id: string?): Face
	if id ~= nil then
		for _, face in FaceConfig.Faces do
			if face.Id == id then
				return face
			end
		end
	end
	return FaceConfig.Faces[1]
end

function FaceConfig.IsValid(id: any): boolean
	if type(id) ~= "string" then
		return false
	end
	for _, face in FaceConfig.Faces do
		if face.Id == id then
			return true
		end
	end
	return false
end

return FaceConfig
