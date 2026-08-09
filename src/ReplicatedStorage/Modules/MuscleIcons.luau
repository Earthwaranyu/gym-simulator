--!strict
--[[
	MuscleIcons — the five training slots, built as little 3D figures.

	Icons.luau draws flat glyphs out of Frames and that is right for a menu tab: a sheet
	of paper, a shopping bag, three sliders. It was wrong for muscles. A chest and a back
	are the same rounded blob in silhouette, and two passes of redrawing them — bolder
	shapes, then stat colours and a name label — did not fix it, because the problem was
	never the linework. A muscle is a volume. Flat art of one has to be *read*; a lit,
	shaded, three-quarter view of one is recognised.

	So each slot gets a `ViewportFrame` with a handful of anchored Parts in it and a
	camera looking down on them from the front left. Still nothing uploaded and nothing
	anyone else drew — the same rule the rest of the game keeps, and the reason the
	Creator Store was not the answer: its free icons are re-uploaded stock art.

	Every figure exposes one number. `SetFlex(0)` is the muscle at rest and `SetFlex(1)`
	is the muscle contracted, and what that means is the figure's own business — the arm
	curls and its bicep swells, the pecs push forward, the lats swing out, the abs
	shorten, the legs bend into a squat. The HUD drives that number with a sine and knows
	none of it, which is what lets a sixth stat arrive with its own figure and no edit
	anywhere else.
]]

local MuscleIcons = {}

export type Figure = {
	Viewport: ViewportFrame,
	-- 0 resting, 1 fully contracted.
	SetFlex: (alpha: number) -> (),
	SetColor: (color: Color3) -> (),
	Destroy: () -> (),
}

-- Front-left and slightly above, which is the angle that shows a chest as a chest and
-- still reads a back's V. Straight-on flattens everything back into the silhouette this
-- module exists to escape.
local CAMERA_OFFSET = Vector3.new(3.1, 1.9, 5.2)

--[[
	A part in the figure's own space, sized in studs and positioned relative to the
	figure's centre. Everything is anchored and collisionless because a ViewportFrame
	does not simulate — it only draws.
]]
local function block(model: Model, name: string, size: Vector3, cf: CFrame, shape: Enum.PartType?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.Size = size
	part.CFrame = cf
	if shape ~= nil then
		part.Shape = shape
	end
	part.Parent = model
	return part
end

local function ball(model: Model, name: string, size: Vector3, cf: CFrame): Part
	return block(model, name, size, cf, Enum.PartType.Ball)
end

--[[
	Rounds a limb off. A cylinder capped at both ends reads as flesh where a rectangle
	reads as a plank, and two spheres are cheaper than a mesh.
]]
local function limb(model: Model, name: string, length: number, thickness: number, cf: CFrame)
	block(model, name, Vector3.new(thickness, length, thickness), cf)
	ball(model, `{name}Top`, Vector3.new(thickness, thickness, thickness), cf * CFrame.new(0, length / 2, 0))
	ball(
		model,
		`{name}Bottom`,
		Vector3.new(thickness, thickness, thickness),
		cf * CFrame.new(0, -length / 2, 0)
	)
end

export type Builder = (model: Model) -> (alpha: number) -> ()

--[[
	Arms — a flexed arm, which is the one muscle picture everybody already knows.

	The upper arm stays put and the forearm swings up around the elbow while the bicep
	swells: a curl. Slot one is also the punch, so this doubles as the fist.
]]
local function buildArms(model: Model): (alpha: number) -> ()
	local shoulder = CFrame.new(-0.55, 0.9, 0)
	limb(model, "Upper", 1.7, 0.85, shoulder * CFrame.new(0, -0.85, 0))
	local bicep = ball(model, "Bicep", Vector3.new(1.15, 1.15, 1.15), shoulder * CFrame.new(0.06, -0.55, 0.1))

	local elbow = shoulder * CFrame.new(0, -1.7, 0)
	local forearm = Instance.new("Model")
	forearm.Name = "Forearm"
	forearm.Parent = model
	limb(forearm, "Lower", 1.5, 0.72, CFrame.new(0, -0.75, 0))
	block(forearm, "Fist", Vector3.new(0.95, 0.9, 0.95), CFrame.new(0, -1.65, 0))

	return function(alpha: number)
		-- Up to 105 degrees of curl, and the bicep grows as it closes.
		local swing = math.rad(-105 * alpha)
		forearm:PivotTo(elbow * CFrame.Angles(swing, 0, 0))
		local swell = 1 + 0.34 * alpha
		bicep.Size = Vector3.new(1.15 * swell, 1.15 * swell, 1.15 * swell)
	end
end

--[[
	Chest — a torso seen from the front, with two pec slabs that press forward.
]]
local function buildChest(model: Model): (alpha: number) -> ()
	block(model, "Torso", Vector3.new(2.5, 3.1, 1.1), CFrame.new(0, 0, 0))
	block(model, "Neck", Vector3.new(0.75, 0.6, 0.75), CFrame.new(0, 1.85, 0))
	block(model, "ShoulderLeft", Vector3.new(0.9, 0.9, 1.05), CFrame.new(-1.6, 1.15, 0))
	block(model, "ShoulderRight", Vector3.new(0.9, 0.9, 1.05), CFrame.new(1.6, 1.15, 0))

	local left = block(model, "PecLeft", Vector3.new(1.15, 1.0, 0.55), CFrame.new(-0.62, 0.75, 0.7))
	local right = block(model, "PecRight", Vector3.new(1.15, 1.0, 0.55), CFrame.new(0.62, 0.75, 0.7))

	return function(alpha: number)
		-- Forward and slightly together, the way a chest looks at the top of a press.
		local push = 0.34 * alpha
		local squeeze = 0.1 * alpha
		left.CFrame = CFrame.new(-0.62 + squeeze, 0.75, 0.7 + push)
		right.CFrame = CFrame.new(0.62 - squeeze, 0.75, 0.7 + push)
		local grow = 1 + 0.22 * alpha
		left.Size = Vector3.new(1.15, 1.0, 0.55 * grow)
		right.Size = Vector3.new(1.15, 1.0, 0.55 * grow)
	end
end

--[[
	Back — the same torso from behind, with the lats that make the V.
]]
local function buildBack(model: Model): (alpha: number) -> ()
	block(model, "Torso", Vector3.new(2.3, 3.1, 1.0), CFrame.new(0, 0, 0))
	block(model, "Neck", Vector3.new(0.75, 0.6, 0.75), CFrame.new(0, 1.85, 0))
	block(model, "Spine", Vector3.new(0.42, 2.9, 0.36), CFrame.new(0, 0, 0.6))

	-- Wedges, so the lats taper into the waist instead of hanging off it as slabs.
	local left = Instance.new("WedgePart")
	left.Name = "LatLeft"
	left.Anchored = true
	left.CanCollide = false
	left.CanQuery = false
	left.Material = Enum.Material.SmoothPlastic
	left.Size = Vector3.new(0.5, 1.9, 1.25)
	left.Parent = model

	local right = left:Clone()
	right.Name = "LatRight"
	right.Parent = model

	local function place(alpha: number)
		-- The spread: the lats swing outward and up, which is the whole gesture.
		local flare = math.rad(16 + 22 * alpha)
		local out = 0.95 + 0.28 * alpha
		left.CFrame = CFrame.new(-out, 0.45, 0.35) * CFrame.Angles(0, math.pi, -flare)
		right.CFrame = CFrame.new(out, 0.45, 0.35) * CFrame.Angles(0, 0, flare)
	end

	place(0)
	return place
end

--[[
	Core — a torso with the six-pack raised off it, folding into a crunch.
]]
local function buildCore(model: Model): (alpha: number) -> ()
	local torso = block(model, "Torso", Vector3.new(2.2, 3.0, 1.0), CFrame.new(0, 0, 0))
	block(model, "Chest", Vector3.new(2.4, 0.8, 1.1), CFrame.new(0, 1.7, 0))

	local abs: { Part } = {}
	for row = 1, 3 do
		for side = -1, 1, 2 do
			local part = block(
				model,
				`Ab{row}_{side}`,
				Vector3.new(0.78, 0.66, 0.34),
				CFrame.new(side * 0.44, 0.85 - (row - 1) * 0.78, 0.62)
			)
			table.insert(abs, part)
		end
	end

	return function(alpha: number)
		-- The stack shortens and each block thickens: a torso folding over.
		local squeeze = 1 - 0.24 * alpha
		local index = 0
		for row = 1, 3 do
			for side = -1, 1, 2 do
				index += 1
				local part = abs[index]
				part.Size = Vector3.new(0.78, 0.66 * squeeze, 0.34 + 0.16 * alpha)
				part.CFrame =
					CFrame.new(side * 0.44, (0.85 - (row - 1) * 0.78) * squeeze, 0.62 + 0.08 * alpha)
			end
		end
		torso.Size = Vector3.new(2.2, 3.0 - 0.4 * alpha, 1.0)
	end
end

--[[
	Legs — hips over two legs that bend into a squat and stand back up.
]]
local function buildLegs(model: Model): (alpha: number) -> ()
	local hips = block(model, "Hips", Vector3.new(2.3, 0.95, 1.1), CFrame.new(0, 1.3, 0))

	local legs: { Model } = {}
	for _, side in { -1, 1 } do
		local leg = Instance.new("Model")
		leg.Name = if side < 0 then "LegLeft" else "LegRight"
		leg.Parent = model
		limb(leg, "Thigh", 1.6, 0.95, CFrame.new(0, -0.8, 0))
		limb(leg, "Shin", 1.4, 0.72, CFrame.new(0, -2.3, 0))
		block(leg, "Foot", Vector3.new(0.8, 0.35, 1.2), CFrame.new(0, -3.15, 0.25))
		table.insert(legs, leg)
	end

	return function(alpha: number)
		-- The hips drop and the legs compress under them. Faked by squashing the whole
		-- leg vertically rather than by articulating a knee, because at forty pixels the
		-- drop is the only part of a squat anyone can see.
		local drop = 0.85 * alpha
		hips.CFrame = CFrame.new(0, 1.3 - drop, 0)
		hips.Size = Vector3.new(2.3 + 0.2 * alpha, 0.95, 1.1)
		for index, leg in legs do
			local side = if index == 1 then -1 else 1
			leg:PivotTo(CFrame.new(side * 0.62, 1.3 - drop, 0) * CFrame.Angles(0, 0, 0))
		end
	end
end

local FIGURES: { [string]: Builder } = {
	Fist = buildArms,
	Chest = buildChest,
	Back = buildBack,
	Core = buildCore,
	Legs = buildLegs,
}

function MuscleIcons.Has(name: string): boolean
	return FIGURES[name] ~= nil
end

--[[
	Builds a figure into `parent` and returns the handle the HUD drives.

	The ViewportFrame gets its own Camera and its own light direction — a viewport is
	lit by nothing at all otherwise, and an unlit model is a flat silhouette, which is
	exactly what this module exists to stop being.
]]
function MuscleIcons.Build(parent: GuiObject, name: string, color: Color3): Figure?
	local builder = FIGURES[name]
	if builder == nil then
		return nil
	end

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = `Figure_{name}`
	viewport.AnchorPoint = Vector2.new(0.5, 0.5)
	viewport.Position = UDim2.fromScale(0.5, 0.5)
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(150, 150, 160)
	viewport.LightColor = Color3.fromRGB(255, 250, 235)
	viewport.LightDirection = Vector3.new(-0.6, -1, -0.4)
	viewport.Parent = parent

	local model = Instance.new("Model")
	model.Name = "Figure"
	model.Parent = viewport

	local pose = builder(model)
	pose(0)

	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(CAMERA_OFFSET, Vector3.new(0, 0.1, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local function setColor(next: Color3)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.Color = next
			end
		end
	end
	setColor(color)

	local figure: Figure = {
		Viewport = viewport,
		SetFlex = pose,
		SetColor = setColor,
		Destroy = function()
			viewport:Destroy()
		end,
	}
	return figure
end

return MuscleIcons
