--!strict
--[[
	StationHighlightController — makes machines findable against their platforms.

	The machines are built from the same primitives as the platforms they stand on, in
	a city of the same primitives, so a bench four studs away reads as more scenery.
	The billboard above it only helps once you already know to look up there.

	One restrained client-side mark: an **outline** in the muscle group's colour, so
	the machine separates from the slab under it. Earlier builds also painted a large
	neon disc under every nearby machine. Those discs covered mats, players and props
	and were regularly mistaken for broken equipment geometry, so findability now stays
	on the silhouette and the existing billboard/map.

	Locked machines are marked too, in grey. A player needs to see the thing they
	cannot use yet: that is the entire reason to keep training.

	Only the nearest handful are marked at a time. `Highlight` is a real per-instance
	renderer cost and Roblox stops honouring them past a few dozen, so lighting up all
	35 courts would mean the ones near you silently stopping working. Distance is re-checked
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
local LOCKED_COLOR = UI.Palette.TextMuted

local player = Players.LocalPlayer

type Mark = {
	highlight: Highlight,
	definition: EquipmentConfig.EquipmentDefinition,
}

local marks: { [Instance]: Mark } = {}
local ProfileController: any = nil

function StationHighlightController:Init()
	ProfileController = Loader.Get("ProfileController")
end

local function unmark(station: Instance)
	local mark = marks[station]
	if mark == nil then
		return
	end
	mark.highlight:Destroy()
	marks[station] = nil
end

local function mark(station: Instance, definition: EquipmentConfig.EquipmentDefinition)
	if marks[station] ~= nil then
		return
	end

	if EquipmentConfig.GetBase(station) == nil then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "StationOutline"
	-- Occluded, not AlwaysOnTop: an outline that shines through the building in front
	-- of it turns a city into a christmas tree. The map finds a machine you cannot
	-- see; this only separates one you can.
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillTransparency = 0.85
	highlight.OutlineTransparency = 0
	highlight.Adornee = station
	highlight.Parent = Workspace.CurrentCamera

	marks[station] = { highlight = highlight, definition = definition }
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
	-- leaving a stale outline behind.
	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(unmark)

	if RunService:IsStudio() then
		print(`[StationHighlightController] marking up to {MAX_MARKED} stations within {RANGE} studs`)
	end
end

return StationHighlightController
