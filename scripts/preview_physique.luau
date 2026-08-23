--!nocheck
--[[
	preview_physique — see every stage of the body at once.

	**Run this in Edit mode, from the command bar.**

	Why it exists: the physique is judged by eye, and there was no way to look at it
	without starting the game, granting stats, and taking one screenshot per stage.
	Several rounds of tuning were spent that way — change one amplitude, restart,
	look, repeat. This lines up the whole growth curve in one place so a single
	screenshot answers "did that help".

	Why Edit rather than Play: a Play client caps live EditableMesh instances at
	seven or eight, and a MeshPart renders nothing once its mesh is freed, so ten
	bodies cannot coexist there. Edit has no such cap. That limit is the reason the
	game builds one skinned mesh per character rather than one per limb, and it is
	worth knowing before wondering why this script refuses to run in Play.

	  PhysiquePreview.show()        -- five growth stages, front row and back row
	  PhysiquePreview.show(0.5)     -- one stage on its own, larger
	  PhysiquePreview.clear()       -- remove them

	The bodies are anchored, unskinned props: they carry the same geometry the game
	builds but no bones are driven, so they stand in the bind pose. That is exactly
	what you want for judging a silhouette.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(not RunService:IsRunning(), "preview_physique must be run in Edit mode, not Play")

--[[
	Load the modules from a throwaway copy rather than requiring them directly.

	Studio's Edit session caches a ModuleScript's result for the life of the session,
	and Rojo replacing the Source does NOT invalidate that cache — nor does entering
	and leaving Play. So a preview that requires the real modules happily rebuilds
	from whatever the code looked like when you first ran it, and you sit there
	tuning numbers that never reach the mesh.

	A cloned ModuleScript is a different instance and so gets its own cache entry.
	Cloning the whole Modules folder keeps every `script.Parent.X` require inside the
	copy, so the chain is fresh all the way down.
]]
local function freshModules(): Folder
	local existing = ReplicatedStorage:FindFirstChild("__PreviewModules")
	if existing then
		existing:Destroy()
	end
	local copy = ReplicatedStorage.Modules:Clone()
	copy.Name = "__PreviewModules"
	copy.Parent = ReplicatedStorage
	return copy
end

local Modules = freshModules()
local BodyLoftBuilder = require(Modules.BodyLoftBuilder)
local BodyLoftConfig = require(Modules.BodyLoftConfig)
local Formulas = require(Modules.Formulas)
local StatConfig = require(Modules.StatConfig)

local FOLDER_NAME = "PhysiquePreview"
local ORIGIN = Vector3.new(0, 500, 0)
local SPACING = 7

local PhysiquePreview = {}
-- The meshes have to outlive the call, or the parts render as nothing.
local retained: { any } = {}

local PALETTE = {
	Skin = Color3.fromRGB(236, 200, 168),
	Pants = Color3.fromRGB(28, 32, 44),
}

local function folder(): Folder
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = workspace
	return created
end

--[[
	The scales the server would publish at a given progress.

	Rebuilt from StatConfig and Formulas rather than typed out, so the preview cannot
	drift from what MuscleService actually sends. A stat's BodyScales weights say
	which parts it grows and by how much; the largest wins, exactly as the server does.
]]
local function scalesFor(progress: number): { [string]: number }
	local scales: { [string]: number } = {}
	for _, definition in StatConfig.List do
		for partName, weight in definition.BodyScales do
			local scale = Formulas.MuscleScaleForProgress(progress, weight)
			if scales[partName] == nil or scale > scales[partName] then
				scales[partName] = scale
			end
		end
	end
	return scales
end

local function buildOne(progress: number, position: Vector3, facing: number, parent: Folder)
	local byStat: { [string]: number } = {}
	for _, definition in StatConfig.List do
		byStat[definition.Id] = progress
	end
	local built = BodyLoftBuilder.Build(byStat, BodyLoftConfig.DETAIL.Near, PALETTE, scalesFor(progress))
	if built == nil then
		warn(`preview_physique: build failed at progress {progress}`)
		return
	end
	table.insert(retained, built.Mesh)
	built.Part.Name = string.format("Physique_%02d", math.floor(progress * 100))
	built.Part.Anchored = true
	built.Part.CanCollide = false
	built.Part.CFrame = CFrame.new(position) * CFrame.Angles(0, facing, 0)
	built.Part.Parent = parent
end

function PhysiquePreview.clear()
	local existing = workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	for _, mesh in retained do
		pcall(function()
			mesh:Destroy()
		end)
	end
	table.clear(retained)
	print("preview_physique: cleared")
end

function PhysiquePreview.show(only: number?)
	PhysiquePreview.clear()
	local parent = folder()
	local stages = if only ~= nil then { only } else { 0, 0.25, 0.5, 0.75, 1 }

	for index, progress in stages do
		local x = (index - 1 - (#stages - 1) / 2) * SPACING
		-- Front row facing the camera, back row behind it and turned around, so one
		-- shot shows the lats and hamstrings as well as the chest.
		buildOne(progress, ORIGIN + Vector3.new(x, 0, 0), 0, parent)
		buildOne(progress, ORIGIN + Vector3.new(x, 0, -SPACING), math.pi, parent)
	end

	local camera = workspace.CurrentCamera
	if camera then
		camera.CFrame = CFrame.lookAt(
			ORIGIN + Vector3.new(0, 1.2, #stages * SPACING * 0.62),
			ORIGIN + Vector3.new(0, -0.3, -SPACING * 0.5)
		)
	end
	print(`preview_physique: {#stages} stages, front and back. Max scale {Formulas.MAX_MUSCLE_SCALE}.`)
end

-- The one global. A command-bar tool has nowhere else to live between runs.
-- selene: allow(global_usage)
_G.PhysiquePreview = PhysiquePreview
PhysiquePreview.show()
return PhysiquePreview
