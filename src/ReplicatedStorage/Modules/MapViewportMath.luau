--!strict
--[[
	Pure geometry for the full-map viewport.

	Roblox's legacy renderer can draw a rotated GuiObject beyond an ancestor with
	ClipsDescendants enabled. The full map therefore never leaves containment to the
	renderer: an item is visible only while its complete rotated axis-aligned bounds fit
	inside the viewport. Keeping this module free of Roblox datatypes makes the rule
	testable by the command-line Luau runner.
]]

local MapViewportMath = {}

function MapViewportMath.RotatedHalfExtents(
	width: number,
	height: number,
	rotationDegrees: number
): (number, number)
	local angle = math.rad(rotationDegrees)
	local cosine = math.abs(math.cos(angle))
	local sine = math.abs(math.sin(angle))
	return cosine * width / 2 + sine * height / 2, sine * width / 2 + cosine * height / 2
end

function MapViewportMath.Fits(
	centerX: number,
	centerY: number,
	width: number,
	height: number,
	rotationDegrees: number,
	viewportWidth: number,
	viewportHeight: number,
	padding: number?
): boolean
	local edgePadding = padding or 0
	local halfX, halfY = MapViewportMath.RotatedHalfExtents(width, height, rotationDegrees)
	return centerX - halfX >= edgePadding
		and centerY - halfY >= edgePadding
		and centerX + halfX <= viewportWidth - edgePadding
		and centerY + halfY <= viewportHeight - edgePadding
end

function MapViewportMath.RunSelfTest(): { string }
	local failures: { string } = {}
	local function expect(name: string, actual: boolean, wanted: boolean)
		if actual ~= wanted then
			table.insert(failures, `{name}: expected {tostring(wanted)}, got {tostring(actual)}`)
		end
	end

	expect("centred unrotated item fits", MapViewportMath.Fits(50, 50, 20, 20, 0, 100, 100), true)
	expect("centred rotated item fits", MapViewportMath.Fits(50, 50, 60, 20, 45, 100, 100), true)
	expect("unrotated item crossing edge is hidden", MapViewportMath.Fits(5, 50, 20, 20, 0, 100, 100), false)
	-- Its unrotated 20 px half-width would fit at x=21. Rotation expands its AABB to
	-- ~28.3 px, reproducing the exact class of leak seen in the Studio screenshots.
	expect(
		"rotated bounds crossing edge are hidden",
		MapViewportMath.Fits(21, 50, 40, 40, 45, 100, 100),
		false
	)
	expect("one-pixel safety gutter is enforced", MapViewportMath.Fits(10, 50, 20, 20, 0, 100, 100, 1), false)

	return failures
end

return MapViewportMath
