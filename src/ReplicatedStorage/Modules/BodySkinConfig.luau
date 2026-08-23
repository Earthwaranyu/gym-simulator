--!strict
--[[
	BodySkinConfig — the physique, as strokes to be drawn.

	The reference art this game is chasing is a blocky Roblox avatar with the muscles
	*painted on a shirt texture*: the pecs, the abs, the delt separations are shadows
	in an image, not shapes in a mesh. Sculpting them into geometry was a long detour —
	a fifth of a stud of bicep on a smoothly-normalled limb is invisible, which is why
	raising the amplitudes bought almost nothing.

	So the body's definition lives here, as lines and blobs drawn into a texture.

	Coordinates are **region-relative**: u and v both run 0..1 inside the tube's column
	of the atlas, and `BodyLoftConfig` rotates the angle so u = 0.5 is the body's front
	centre line. v follows the tube's authored direction — the torso runs hips-to-neck,
	the limbs run shoulder-to-wrist and hip-to-ankle — so v = 0 is the hip on a leg and
	the waist on the torso.

	`Depth` is how dark the shadow goes at the centre of the stroke, as a fraction
	toward black, and `Width` is its half-thickness in region units. Strokes darken
	whatever base colour is underneath rather than painting a fixed grey, so every skin
	tone in the creator works without a second set of numbers.

	Widths look large next to the first version of this file, and deliberately so. The
	torso only owns half of a 512-pixel texture, so a width of 0.007 came out under two
	pixels across — a scratch, not a shadow, and on screen it read as dirt on a smooth
	body. These now sit in the grooves that `BodyLoftConfig` cuts, so the geometry and
	the shading agree; where they disagreed was most of why the old ones looked wrong.

	Adding a muscle line is a row here. The painter never needs to change.
]]

local BodySkinConfig = {}

export type Stroke = {
	Id: string,
	Region: string,
	-- Start and end, in region-relative 0..1.
	U0: number,
	V0: number,
	U1: number,
	V1: number,
	Width: number,
	Depth: number,
	-- Progress at which the stroke starts appearing and reaches full strength. A lean
	-- body has no ab separations; they arrive with the muscle.
	Start: number,
	Full: number,
	-- Which stat's progress drives it.
	StatId: string,
}

local strokes: { Stroke } = {}

local function stroke(
	id: string,
	region: string,
	statId: string,
	u0: number,
	v0: number,
	u1: number,
	v1: number,
	width: number,
	depth: number,
	start: number,
	full: number
)
	table.insert(strokes, {
		Id = id,
		Region = region,
		StatId = statId,
		U0 = u0,
		V0 = v0,
		U1 = u1,
		V1 = v1,
		Width = width,
		Depth = depth,
		Start = start,
		Full = full,
	})
end

-- === Torso ==================================================================
-- v: 0 at the waist, 1 at the neck. u: 0.5 dead centre front, 0 and 1 the spine.

-- The line down the middle of the abdomen, and the three separations across it.
stroke("LineaAlba", "Torso", "Core", 0.5, 0.30, 0.5, 0.63, 0.0216, 0.405, 0.20, 0.75)
for row, v in { 0.38, 0.47, 0.56 } do
	stroke(`AbRow{row}`, "Torso", "Core", 0.44, v, 0.56, v, 0.026, 0.38, 0.22 + row * 0.06, 0.85)
end
-- Obliques, angling down toward the groin.
for _, side in { -1, 1 } do
	local tag = if side < 0 then "L" else "R"
	stroke(
		`Oblique{tag}`,
		"Torso",
		"Core",
		0.5 + side * 0.10,
		0.60,
		0.5 + side * 0.055,
		0.30,
		0.0288,
		0.297,
		0.35,
		0.95
	)
	-- Serratus: the short fingers above the obliques.
	for index = 0, 2 do
		local v = 0.58 + index * 0.045
		stroke(
			`Serratus{tag}{index}`,
			"Torso",
			"Core",
			0.5 + side * 0.105,
			v,
			0.5 + side * 0.145,
			v + 0.03,
			0.0216,
			0.243,
			0.50,
			1.00
		)
	end
end

-- Pectorals: the cleft between them, and the shadow under each.
stroke("PecCleft", "Torso", "Chest", 0.5, 0.68, 0.5, 0.84, 0.0252, 0.378, 0.12, 0.70)
for _, side in { -1, 1 } do
	local tag = if side < 0 then "L" else "R"
	stroke(
		`PecUnder{tag}`,
		"Torso",
		"Chest",
		0.5 + side * 0.02,
		0.685,
		0.5 + side * 0.135,
		0.72,
		0.0396,
		0.432,
		0.15,
		0.78
	)
	stroke(
		`PecOuter{tag}`,
		"Torso",
		"Chest",
		0.5 + side * 0.135,
		0.72,
		0.5 + side * 0.16,
		0.83,
		0.0324,
		0.324,
		0.25,
		0.85
	)
end

-- Back: the spine channel, the lat sweep and the trapezius wedge. u near 0 and 1.
stroke("SpineL", "Torso", "Back", 0.015, 0.35, 0.015, 0.80, 0.0252, 0.351, 0.25, 0.88)
stroke("SpineR", "Torso", "Back", 0.985, 0.35, 0.985, 0.80, 0.0252, 0.351, 0.25, 0.88)
for _, side in { -1, 1 } do
	local tag = if side < 0 then "L" else "R"
	local u = if side < 0 then 0.07 else 0.93
	stroke(`Lat{tag}`, "Torso", "Back", u, 0.40, u + side * -0.045, 0.74, 0.0432, 0.378, 0.18, 0.85)
	stroke(
		`Trap{tag}`,
		"Torso",
		"Back",
		u + side * -0.02,
		0.86,
		u + side * 0.05,
		0.95,
		0.036,
		0.324,
		0.28,
		0.90
	)
end

-- === Arms ===================================================================
-- v: 0 at the shoulder cap, 1 at the wrist.

for _, side in { "Left", "Right" } do
	local region = `{side}Arm`
	-- The deltoid's lower edge, right around the arm.
	stroke(`{side}DeltEdge`, region, "Arms", 0.0, 0.20, 1.0, 0.20, 0.036, 0.324, 0.10, 0.70)
	-- Bicep and tricep, split along the two sides of the arm.
	stroke(`{side}BicepSplit`, region, "Arms", 0.5, 0.24, 0.5, 0.46, 0.0288, 0.297, 0.18, 0.80)
	stroke(`{side}TricepSplit`, region, "Arms", 0.0, 0.26, 0.0, 0.48, 0.0288, 0.351, 0.24, 0.88)
	stroke(`{side}TricepSplit2`, region, "Arms", 1.0, 0.26, 1.0, 0.48, 0.0288, 0.351, 0.24, 0.88)
	-- Elbow, then the forearm's central channel.
	stroke(`{side}Elbow`, region, "Arms", 0.0, 0.55, 1.0, 0.55, 0.0288, 0.27, 0.30, 0.90)
	stroke(`{side}Forearm`, region, "Arms", 0.5, 0.60, 0.5, 0.82, 0.0252, 0.243, 0.35, 1.00)
end

-- === Legs ===================================================================
-- v: 0 at the hip, 1 at the ankle. The upper third is under the shorts.

for _, side in { "Left", "Right" } do
	local region = `{side}Leg`
	-- Quadriceps sweep, then the knee, then the calf split.
	stroke(`{side}QuadInner`, region, "Legs", 0.44, 0.34, 0.47, 0.58, 0.036, 0.297, 0.15, 0.80)
	stroke(`{side}QuadOuter`, region, "Legs", 0.60, 0.34, 0.56, 0.58, 0.036, 0.297, 0.15, 0.80)
	stroke(`{side}Knee`, region, "Legs", 0.36, 0.63, 0.64, 0.63, 0.0324, 0.243, 0.25, 0.85)
	stroke(`{side}CalfSplit`, region, "Legs", 0.0, 0.70, 0.0, 0.86, 0.0324, 0.324, 0.28, 0.95)
	stroke(`{side}CalfSplit2`, region, "Legs", 1.0, 0.70, 1.0, 0.86, 0.0324, 0.324, 0.28, 0.95)
end

BodySkinConfig.STROKES = strokes

-- Texture resolution. 512 is the smallest that keeps an ab separation crisp once the
-- torso only owns half the width; 1024 costs four times the fill for no visible gain
-- at the distance players actually see each other.
BodySkinConfig.RESOLUTION = 512

-- Crease intensity is quantised so the cache stays small: a body rebuilding across
-- twenty-four growth steps would otherwise want twenty-four textures per skin tone.
BodySkinConfig.STAGES = 6

function BodySkinConfig.Strength(s: Stroke, progress: number): number
	local span = s.Full - s.Start
	if span <= 0 then
		return 0
	end
	local linear = math.clamp((progress - s.Start) / span, 0, 1)
	return linear * linear * (3 - 2 * linear)
end

function BodySkinConfig.RunSelfTest(): { string }
	local failures: { string } = {}
	local validStats = { Arms = true, Chest = true, Back = true, Core = true, Legs = true }
	local validRegions = {
		Torso = true,
		LeftArm = true,
		RightArm = true,
		LeftLeg = true,
		RightLeg = true,
	}
	local ids: { [string]: boolean } = {}
	local perRegion: { [string]: number } = {}
	for _, s in strokes do
		if ids[s.Id] then
			table.insert(failures, `duplicate stroke {s.Id}`)
		end
		ids[s.Id] = true
		if not validStats[s.StatId] then
			table.insert(failures, `{s.Id} uses unknown stat {s.StatId}`)
		end
		if not validRegions[s.Region] then
			table.insert(failures, `{s.Id} draws on unknown region {s.Region}`)
		end
		perRegion[s.Region] = (perRegion[s.Region] or 0) + 1
		for _, value in { s.U0, s.U1, s.V0, s.V1 } do
			if value < 0 or value > 1 then
				table.insert(failures, `{s.Id} runs outside its region`)
				break
			end
		end
		if s.Width <= 0 or s.Width > 0.06 then
			-- A stroke wider than this is a smudge, not a crease.
			table.insert(failures, `{s.Id} has an implausible width`)
		end
		-- Under about a hundredth of a region the stroke lands on fewer than three
		-- pixels of a 512 texture and reads as a scratch rather than a shadow. That
		-- is what the first version of this file got wrong across the board.
		if s.Width < 0.012 then
			table.insert(failures, `{s.Id} is too thin to read at texture resolution`)
		end
		if s.Depth <= 0 or s.Depth > 0.5 then
			-- Past this the shadow reads as dirt rather than shape.
			table.insert(failures, `{s.Id} has a depth outside the shadow range`)
		end
		if s.Start < 0 or s.Full > 1 or s.Start >= s.Full then
			table.insert(failures, `{s.Id} has an invalid growth range`)
		end
		if BodySkinConfig.Strength(s, 0) ~= 0 then
			table.insert(failures, `{s.Id} shows on an untrained body`)
		end
	end
	-- Every region must carry some definition, or a limb reads as a bare tube.
	for region in validRegions do
		if (perRegion[region] or 0) == 0 then
			table.insert(failures, `{region} has no strokes at all`)
		end
	end
	-- Left and right must be drawn the same amount.
	if perRegion.LeftArm ~= perRegion.RightArm or perRegion.LeftLeg ~= perRegion.RightLeg then
		table.insert(failures, "left and right limbs carry different amounts of detail")
	end
	return failures
end

return BodySkinConfig
