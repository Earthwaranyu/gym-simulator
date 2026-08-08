--!strict
--[[
	StationHighlightController — makes machines findable against their platforms.

	The machines are built from the same primitives as the platforms they stand on, in
	a city of the same primitives, so a bench four studs away reads as more scenery.
	The billboard above it only helps once you already know to look up there.

	Two marks, both client-side and both cheap:

	  * an **outline** in the muscle group's colour, so the machine separates from the
	    slab under it, and
	  * a **floor ring** at its base, which is what you actually see first when running
	    past at Legs speed — the outline is a silhouette, the ring is a target.

	Locked machines are marked too, in grey. A player needs to see the thing they
	cannot use yet: that is the entire reason to keep training.

	Only the nearest handful are marked at a time. `Highlight` is a real per-instance
	renderer cost and Roblox stops honouring them past a few dozen, so lighting up all
	55 would mean the ones near you silently stopping working. Distance is re-checked
	on a timer rather than per frame, because a machine does not move and neither does
	a player fast enough to notice a quarter-second of lag in an outline.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local StationHighlightController = {
	Name = "StationHighlightController",
	Priority = 11,
}

-- How many machines carry a mark at once. Comfortably under the point where Roblox
-- starts dropping Highlights, and more than are ever visible from one spot.
local MAX_MARKED = 14
-- Past this, the machine is a map problem rather than a "which one is it" problem.
local RANGE = 260
local REFRESH_SECONDS = 0.35

-- Grey for locked. Deliberately not red: locked is "not yet", not "wrong".
local LOCKED_COLOR = Color3.fromRGB(150, 158, 175)

local player = Players.LocalPlayer

type Mark = {
	highlight: Highlight,
	ring: Part,
	definition: EquipmentConfig.EquipmentDefinition,
}

local marks: { [Instance]: Mark } = {}
local ProfileController: any = nil

function StationHighlightController:Init()
	ProfileController = Loader.Get("ProfileController")
end

--[[
	The floor ring, sized to the machine's own footprint so a squat rack gets a wider
	one than a dumbbell rack.
]]
local function buildRing(station: Instance, base: BasePart): Part?
	local width = base.Size.X
	local depth = base.Size.Z
	local floorY = base.Position.Y - base.Size.Y / 2

	if station:IsA("Model") then
		local boundsCFrame, boundsSize = station:GetBoundingBox()
		width = boundsSize.X
		depth = boundsSize.Z
		floorY = boundsCFrame.Position.Y - boundsSize.Y / 2
	end

	local ring = Instance.new("Part")
	ring.Name = "StationRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Transparency = 0.55
	-- A cylinder's height runs along X, so it has to be laid on its side to become a
	-- disc on the floor.
	local diameter = math.max(width, depth) * 1.5
	ring.Size = Vector3.new(0.12, diameter, diameter)
	ring.CFrame = CFrame.new(base.Position.X, floorY + 0.08, base.Position.Z)
		* CFrame.Angles(0, 0, math.rad(90))

	-- Under the camera so it never replicates and never survives into another
	-- player's world; each client draws its own.
	ring.Parent = Workspace.CurrentCamera
	return ring
end

local function unmark(station: Instance)
	local mark = marks[station]
	if mark == nil then
		return
	end
	mark.highlight:Destroy()
	mark.ring:Destroy()
	marks[station] = nil
end

local function mark(station: Instance, definition: EquipmentConfig.EquipmentDefinition)
	if marks[station] ~= nil then
		return
	end

	local base = EquipmentConfig.GetBase(station)
	if base == nil then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "StationOutline"
	-- Occluded, not AlwaysOnTop: an outline that shines through the building in front
	-- of it turns a city into a christmas tree. The floor ring and the map are what
	-- find a machine you cannot see; this only separates one you can.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 0.85
	highlight.OutlineTransparency = 0
	highlight.Adornee = station
	highlight.Parent = Workspace.CurrentCamera

	local ring = buildRing(station, base)
	if ring == nil then
		highlight:Destroy()
		return
	end

	marks[station] = { highlight = highlight, ring = ring, definition = definition }
end

--[[
	Re-picks which machines are marked, and recolours them for the current power.
]]
function StationHighlightController:_refresh()
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		for station in marks do
			unmark(station)
		end
		return
	end

	local origin = (root :: BasePart).Position

	-- Nearest first, so the cut at MAX_MARKED drops the machines furthest away.
	local candidates: { { station: Instance, distance: number, definition: any } } = {}
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		local base = EquipmentConfig.GetBase(station)
		if base == nil then
			continue
		end
		local distance = (base.Position - origin).Magnitude
		if distance > RANGE then
			continue
		end
		local definition = EquipmentConfig.Resolve(station)
		if definition == nil then
			continue
		end
		table.insert(candidates, { station = station, distance = distance, definition = definition })
	end

	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)

	local keep: { [Instance]: boolean } = {}
	for index, candidate in candidates do
		if index > MAX_MARKED then
			break
		end
		keep[candidate.station] = true
		mark(candidate.station, candidate.definition)
	end

	for station in marks do
		if not keep[station] then
			unmark(station)
		end
	end

	-- Colour by muscle group, dimmed to grey while locked.
	local data = ProfileController:Get()
	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0

	for _, entry in marks do
		local definition = entry.definition
		local owned = data ~= nil and data.OwnedEquipment[definition.Id] == true
		local unlocked = owned or power >= definition.UnlockPower

		local statDefinition = StatConfig.Get(definition.StatId)
		local color = if not unlocked
			then LOCKED_COLOR
			elseif statDefinition ~= nil then statDefinition.Color
			else UI.Palette.Text

		entry.highlight.OutlineColor = color
		entry.highlight.FillColor = color
		entry.highlight.FillTransparency = if unlocked then 0.85 else 0.93
		entry.ring.Color = color
		entry.ring.Transparency = if unlocked then 0.55 else 0.8
	end
end

function StationHighlightController:Start()
	-- Everything is parented to CurrentCamera, which Roblox replaces on respawn. The
	-- next refresh rebuilds anything that went with it.
	player.CharacterAdded:Connect(function()
		table.clear(marks)
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			-- A failure in a cosmetic loop must not stop the loop.
			local ok, err = pcall(function()
				self:_refresh()
			end)
			if not ok then
				warn(`[StationHighlightController] {err}`)
			end
		end
	end)

	-- Streaming can remove a station out from under a mark; drop it rather than
	-- leaving a ring glowing over empty ground.
	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(unmark)

	if RunService:IsStudio() then
		print(`[StationHighlightController] marking up to {MAX_MARKED} stations within {RANGE} studs`)
	end
end

return StationHighlightController
