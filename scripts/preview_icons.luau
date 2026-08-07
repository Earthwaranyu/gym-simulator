--!nocheck
--[[
	preview_icons — look at the interface icons.

	Paste into Studio's command bar (Edit mode) and run. It leaves a row of the
	glyphs floating at y = 400; run it again to refresh, or set CLEAN_UP below to
	remove them.

	Why this exists: Studio's screen capture renders the 3D viewport and NOT GUIs.
	A SurfaceGui filled edge to edge with bright green photographs as a black
	rectangle. So there is no way to look at a ScreenGui through the automation,
	and icons drawn from Frames were being written blind.

	This draws each icon for real, lets Roblox lay it out, then reads back every
	Frame's computed position and size and mirrors it into a Part. What you see is
	the geometry Icons.Draw actually produced, not a second copy of the design —
	which is the whole point, and is how Shop was caught being the same diamond as
	Map.

	Two things the proxy cannot show, so do not read anything into them:
	  * UICorner. Every shape appears square here; the real glyphs are rounded.
	  * UIStroke. Outlines are dropped.

	And one Studio trap it works around: Rojo updates a ModuleScript's Source in
	place, while `require` caches per instance — so a plain require returns
	whatever was first loaded this session. Cloning the module forces a fresh one.
]]

local CLEAN_UP = false

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CoreGui = game:GetService("CoreGui")

local FOLDER_NAME = "_IconProxy"
local TILE = 200 -- pixels each icon is laid out at
local STUDS = 12 -- studs it is drawn at
local HEIGHT = 400 -- where the row floats
local GAP = 5

local existing = workspace:FindFirstChild(FOLDER_NAME)
if existing then
	existing:Destroy()
end
if CLEAN_UP then
	return
end

local fresh = ReplicatedStorage.Modules.Icons:Clone()
fresh.Parent = ReplicatedStorage
local Icons = require(fresh)

local folder = Instance.new("Folder")
folder.Name = FOLDER_NAME
folder.Parent = workspace

local holder = Instance.new("ScreenGui")
holder.Parent = CoreGui

local ACCENT = Color3.fromRGB(255, 196, 61)
local TILE_COLOR = Color3.fromRGB(30, 33, 44)

--[[
	How deep a frame sits, so children can be pushed in front of their parent and
	a knockout is not lost to z-fighting with the shape it is punched out of.
]]
local function depthOf(node, root)
	local depth, cursor = 0, node.Parent
	while cursor ~= nil and cursor ~= root do
		depth += 1
		cursor = cursor.Parent
	end
	return depth
end

--[[
	AbsolutePosition ignores Rotation, and a child of a rotated frame inherits
	that rotation on screen without reporting it. Both have to be accumulated.
]]
local function rotationOf(node, root)
	local total, cursor = 0, node
	while cursor ~= nil and cursor ~= root do
		total += cursor.Rotation or 0
		cursor = cursor.Parent
	end
	return total
end

local names = { "Map", "Upgrades", "Shop", "Top", "Settings" }
local report = {}

for index, name in names do
	local box = Instance.new("Frame")
	box.Size = UDim2.fromOffset(TILE, TILE)
	box.BackgroundTransparency = 1
	box.Parent = holder

	Icons.Draw(name, box, ACCENT, TILE_COLOR)
	task.wait(0.05) -- let the layout settle before reading it back

	-- Mirrored on X so a camera on -Z sees them in declaration order.
	local originX = ((#names + 1) / 2 - index) * (STUDS + GAP)
	local shapes = 0

	for _, frame in box:GetDescendants() do
		if not frame:IsA("Frame") or frame.BackgroundTransparency == 1 then
			continue
		end
		shapes += 1

		local centre = frame.AbsolutePosition - box.AbsolutePosition + frame.AbsoluteSize / 2
		local part = Instance.new("Part")
		part.Name = frame.Name
		part.Anchored = true
		part.CanCollide = false
		part.Material = Enum.Material.Neon
		part.Color = frame.BackgroundColor3
		part.Size = Vector3.new(
			math.max(frame.AbsoluteSize.X / TILE * STUDS, 0.1),
			math.max(frame.AbsoluteSize.Y / TILE * STUDS, 0.1),
			0.3
		)
		part.CFrame = CFrame.new(
			originX + (centre.X / TILE - 0.5) * STUDS,
			HEIGHT - (centre.Y / TILE - 0.5) * STUDS,
			-0.35 * depthOf(frame, box)
		) * CFrame.Angles(0, 0, -math.rad(rotationOf(frame, box)))
		part.Parent = folder
	end

	table.insert(report, ("%-9s %d shapes"):format(name, shapes))
	box:Destroy()
end

holder:Destroy()
fresh:Destroy()

local backdrop = Instance.new("Part")
backdrop.Name = "Backdrop"
backdrop.Anchored = true
backdrop.CanCollide = false
backdrop.Material = Enum.Material.SmoothPlastic
backdrop.Color = TILE_COLOR
backdrop.Size = Vector3.new(#names * (STUDS + GAP) + 12, STUDS + 10, 0.4)
backdrop.CFrame = CFrame.new(0, HEIGHT, 1.2)
backdrop.Parent = folder

print(table.concat(report, "\n"))
print(("look from about (0, %d, -48) toward (0, %d, 0)"):format(HEIGHT, HEIGHT))
