--!strict
--[[
	BodyMeshConfig — where the generated body is cut into R15 parts.

	The body players see is one AI-generated mesh, sliced into the fourteen pieces
	an R15 rig needs. This file owns the slicing: the source asset and the planes
	the cuts run along. `BodyMeshBuilder` does the cutting, `BodyMeshController`
	puts the result on characters, and neither of them decides anything.

	Why one mesh cut by us, rather than fourteen generated parts:

	The mesh generator sculpts well and segments badly. Asked for named parts it
	carves the geometry at arbitrary places — a measured run returned a
	RightUpperArm 2.11 studs tall against a LeftUpperArm of 1.24, with both legs
	merged into LowerTorso. Harmless in a statue, fatal in a rig: every part must
	begin and end exactly at its joint or the character comes apart the moment it
	animates. Generating the body in one piece gives the best definition *and*
	exact mirror symmetry, so we take that and choose the cuts ourselves.

	The planes below are measurements, not guesses. They came from binning the
	source mesh's vertices by height and reading where the silhouette changes:
	where the head narrows, where the arms stop overlapping the torso, where a
	single span becomes two legs. Regenerating the source mesh invalidates every
	number here — they describe this sculpt's proportions, not anatomy in general.

	Everything is plain numbers rather than Vector3, so this file stays requireable
	by the bare `luau` CLI and its self-test runs in check.sh rather than only in
	Studio. That self-test is what stops a mistyped plane from producing a body
	with no forearms, which is not obvious from a list of decimals.
]]

local BodyMeshConfig = {}

-- The uncut whole-body sculpt. Regenerating the body means a new id here and a
-- fresh round of measurement for every plane below.
BodyMeshConfig.SOURCE_ASSET_ID = 100179582688381

-- Vertical extent of the source mesh, in its own coordinates. Used by the
-- self-test to check the planes actually fall inside the body.
BodyMeshConfig.SOURCE_MIN_Y = -2.8
BodyMeshConfig.SOURCE_MAX_Y = 2.8

--[[
	The cut planes. All but SHOULDER_X are heights; SHOULDER_X is a distance from
	the centre line, because arms separate from the torso sideways rather than
	vertically.
]]
-- Below the head. The game keeps the stock R15 head, so everything above this is
-- discarded rather than assigned to a part.
BodyMeshConfig.NECK = 2.36
-- Past the deltoid, where an arm stops overlapping the ribcage.
BodyMeshConfig.SHOULDER_X = 0.62
BodyMeshConfig.ELBOW = 1.03
BodyMeshConfig.WRIST = -0.02
-- Fingertips. Nothing below this on the arms belongs to the body.
BodyMeshConfig.HAND_END = -0.35
BodyMeshConfig.WAIST = -0.15
-- The crotch: the height at which one torso silhouette first reads as two legs.
BodyMeshConfig.HIP = -0.62
BodyMeshConfig.KNEE = -1.60
-- Where the foot starts to flare out of the ankle.
BodyMeshConfig.ANKLE = -2.42

--[[
	Which R15 part a triangle belongs to, given its centroid.

	Returns nil for geometry that is deliberately dropped: the head, and the empty
	space below the hands where an arm's column continues past the fingers.
]]
function BodyMeshConfig.Region(x: number, y: number): string?
	if y > BodyMeshConfig.NECK then
		return nil
	end

	local side = if x < 0 then "Left" else "Right"

	if y > BodyMeshConfig.HIP then
		-- Out past the ribcage: this is an arm, and which segment depends on height.
		if math.abs(x) > BodyMeshConfig.SHOULDER_X then
			if y > BodyMeshConfig.ELBOW then
				return side .. "UpperArm"
			elseif y > BodyMeshConfig.WRIST then
				return side .. "LowerArm"
			elseif y > BodyMeshConfig.HAND_END then
				return side .. "Hand"
			end
			return nil
		end
		return if y > BodyMeshConfig.WAIST then "UpperTorso" else "LowerTorso"
	end

	if y > BodyMeshConfig.KNEE then
		return side .. "UpperLeg"
	elseif y > BodyMeshConfig.ANKLE then
		return side .. "LowerLeg"
	end
	return side .. "Foot"
end

--[[
	Every part the cut is expected to produce. The controller swaps exactly these
	and leaves Head alone.
]]
BodyMeshConfig.PART_NAMES = {
	"UpperTorso",
	"LowerTorso",
	"LeftUpperArm",
	"RightUpperArm",
	"LeftLowerArm",
	"RightLowerArm",
	"LeftHand",
	"RightHand",
	"LeftUpperLeg",
	"RightUpperLeg",
	"LeftLowerLeg",
	"RightLowerLeg",
	"LeftFoot",
	"RightFoot",
}

-- Pairs that must mirror. Asymmetry is the failure a player notices first and the
-- one a table of decimals hides best.
BodyMeshConfig.MIRROR_PAIRS = {
	{ "LeftUpperArm", "RightUpperArm" },
	{ "LeftLowerArm", "RightLowerArm" },
	{ "LeftHand", "RightHand" },
	{ "LeftUpperLeg", "RightUpperLeg" },
	{ "LeftLowerLeg", "RightLowerLeg" },
	{ "LeftFoot", "RightFoot" },
}

function BodyMeshConfig.RunSelfTest(): { string }
	local failures: { string } = {}

	local function check(label: string, condition: boolean)
		if not condition then
			table.insert(failures, label)
		end
	end

	-- The planes must descend in anatomical order. Swapping any neighbouring pair
	-- silently deletes the part between them.
	local ordered: { { Name: string, Y: number } } = {
		{ Name = "NECK", Y = BodyMeshConfig.NECK },
		{ Name = "ELBOW", Y = BodyMeshConfig.ELBOW },
		{ Name = "WRIST", Y = BodyMeshConfig.WRIST },
		{ Name = "HAND_END", Y = BodyMeshConfig.HAND_END },
		{ Name = "KNEE", Y = BodyMeshConfig.KNEE },
		{ Name = "ANKLE", Y = BodyMeshConfig.ANKLE },
	}
	for i = 2, #ordered do
		local above, below = ordered[i - 1], ordered[i]
		check(`{above.Name} sits above {below.Name}`, above.Y > below.Y)
	end
	check("waist sits above the hip", BodyMeshConfig.WAIST > BodyMeshConfig.HIP)
	check("neck sits above the waist", BodyMeshConfig.NECK > BodyMeshConfig.WAIST)

	-- Every plane has to fall inside the mesh, or it cuts nothing.
	for _, entry in ordered do
		check(
			`{entry.Name} falls inside the source mesh`,
			entry.Y > BodyMeshConfig.SOURCE_MIN_Y and entry.Y < BodyMeshConfig.SOURCE_MAX_Y
		)
	end
	check("shoulder plane is off the centre line", BodyMeshConfig.SHOULDER_X > 0)

	-- The real check: sample the body and confirm every expected part actually
	-- receives geometry. A plane typo usually leaves a part empty rather than
	-- producing anything visibly wrong in the numbers above.
	local seen: { [string]: boolean } = {}
	local STEPS = 60
	for i = 0, STEPS do
		local y = BodyMeshConfig.SOURCE_MIN_Y
			+ (BodyMeshConfig.SOURCE_MAX_Y - BodyMeshConfig.SOURCE_MIN_Y) * i / STEPS
		for _, x in { -1.2, -0.9, -0.3, 0.3, 0.9, 1.2 } do
			local part = BodyMeshConfig.Region(x, y)
			if part ~= nil then
				seen[part] = true
			end
		end
	end
	for _, name in BodyMeshConfig.PART_NAMES do
		check(`{name} receives geometry`, seen[name] == true)
	end

	-- Mirrored parts must be reachable at mirrored sample points, which is what
	-- catches a sign error in Region.
	for _, pair in BodyMeshConfig.MIRROR_PAIRS do
		local left, right = pair[1], pair[2]
		local sampled = false
		for i = 0, STEPS do
			local y = BodyMeshConfig.SOURCE_MIN_Y
				+ (BodyMeshConfig.SOURCE_MAX_Y - BodyMeshConfig.SOURCE_MIN_Y) * i / STEPS
			for _, x in { 0.3, 0.9, 1.2 } do
				if BodyMeshConfig.Region(-x, y) == left and BodyMeshConfig.Region(x, y) == right then
					sampled = true
				end
			end
		end
		check(`{left} mirrors {right}`, sampled)
	end

	-- The head must be dropped, not silently folded into the torso.
	check("head is discarded", BodyMeshConfig.Region(0, BodyMeshConfig.NECK + 0.1) == nil)

	return failures
end

return BodyMeshConfig
