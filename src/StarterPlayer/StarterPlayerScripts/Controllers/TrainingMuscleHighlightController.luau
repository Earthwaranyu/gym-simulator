--!strict
--[[
	TrainingMuscleHighlightController — white anatomical feedback while training.

	The broad R15 body part receives a restrained white wash so the cue is readable
	even on a brand-new physique. Sculpted contours for that stat receive the brighter
	fill: Chest lights the pecs, Back the lats/traps, Core the abs/obliques, and so on.
	No geometry is recoloured, so stopping can remove every effect on the same frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local MuscleDefinitionConfig = require(ReplicatedStorage.Modules.MuscleDefinitionConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Types = require(ReplicatedStorage.Modules.Types)

local TrainingMuscleHighlightController = {
	Name = "TrainingMuscleHighlightController",
	Priority = 41,
}

local HIGHLIGHT_FOLDER_NAME = "TrainingMuscleHighlights"
local WHITE = Color3.new(1, 1, 1)

local player = Players.LocalPlayer
local character: Model? = nil
local currentStat: Types.StatId? = nil
local suppressReplicated = false
local highlights: { [Instance]: Highlight } = {}
local characterConnections: { RBXScriptConnection } = {}

local function disconnectCharacter()
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)
end

local function clearHighlights()
	for _, highlight in highlights do
		highlight:Destroy()
	end
	table.clear(highlights)

	if character ~= nil then
		local folder = character:FindFirstChild(HIGHLIGHT_FOLDER_NAME)
		if folder ~= nil then
			folder:Destroy()
		end
	end
end

local function highlightFolder(): Folder?
	if character == nil or character.Parent == nil then
		return nil
	end
	local existing = character:FindFirstChild(HIGHLIGHT_FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = HIGHLIGHT_FOLDER_NAME
	folder.Parent = character
	return folder
end

local function addHighlight(part: BasePart, sculpted: boolean)
	local folder = highlightFolder()
	if folder == nil then
		return
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = `Training_{part.Name}`
	highlight.Adornee = part
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.FillColor = WHITE
	highlight.OutlineColor = WHITE
	-- Keep the block underneath subtle. The brighter definition contours make the
	-- actual muscle belly, rather than the whole limb, the focus of the effect.
	highlight.FillTransparency = if sculpted then 0.52 else 0.84
	highlight.OutlineTransparency = if sculpted then 0.06 else 0.32
	highlight.Parent = folder
	highlights[part] = highlight
end

local function addMatchingContour(descendant: Instance)
	if currentStat == nil or not descendant:IsA("BasePart") then
		return
	end
	if descendant:GetAttribute(MuscleDefinitionConfig.FEATURE_STAT_ATTRIBUTE) == currentStat then
		addHighlight(descendant, true)
		return
	end
	local shellStats = descendant:GetAttribute(MuscleDefinitionConfig.SHELL_STATS_ATTRIBUTE)
	if type(shellStats) == "string" and string.find(`,{shellStats},`, `,{currentStat},`, 1, true) ~= nil then
		addHighlight(descendant, false)
	end
end

local function render(statId: Types.StatId?)
	clearHighlights()
	currentStat = statId
	if character == nil or statId == nil then
		return
	end

	local bodyParts = MuscleDefinitionConfig.BodyPartsByStat[statId]
	if bodyParts ~= nil then
		for _, partName in bodyParts do
			local part = character:FindFirstChild(partName)
			if part ~= nil and part:IsA("BasePart") then
				addHighlight(part, false)
			end
		end
	end
	for _, descendant in character:GetDescendants() do
		addMatchingContour(descendant)
	end
end

local function replicatedStat(): Types.StatId?
	if character == nil then
		return nil
	end
	local value = character:GetAttribute(MuscleDefinitionConfig.TRAINING_ATTRIBUTE)
	if type(value) == "string" and StatConfig.IsValid(value) then
		return value
	end
	return nil
end

local function watchCharacter(nextCharacter: Model)
	disconnectCharacter()
	clearHighlights()
	character = nextCharacter
	currentStat = nil
	suppressReplicated = false

	table.insert(
		characterConnections,
		nextCharacter:GetAttributeChangedSignal(MuscleDefinitionConfig.TRAINING_ATTRIBUTE):Connect(function()
			suppressReplicated = false
			render(replicatedStat())
		end)
	)
	table.insert(
		characterConnections,
		nextCharacter.DescendantAdded:Connect(function(descendant: Instance)
			addMatchingContour(descendant)
		end)
	)
	table.insert(
		characterConnections,
		nextCharacter.DescendantRemoving:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				highlights[descendant] = nil
			end
		end)
	)

	render(replicatedStat())
end

-- The HUD calls this on press/release so manual training feedback does not wait for
-- a remote round-trip. Passing nil deliberately suppresses the previous replicated
-- value until the server publishes its matching stop.
function TrainingMuscleHighlightController:SetLocalStat(statId: Types.StatId?)
	if statId ~= nil and not StatConfig.IsValid(statId) then
		return
	end
	suppressReplicated = statId == nil
	render(statId)
end

function TrainingMuscleHighlightController:Start()
	local TrainingController = Loader.Get("TrainingController")

	TrainingController.StopRequested:Connect(function()
		self:SetLocalStat(nil)
	end)
	TrainingController.Changed:Connect(function(state: Types.TrainingState)
		if state.StationId ~= nil then
			local definition = EquipmentConfig.Get(state.StationId)
			if definition ~= nil then
				suppressReplicated = false
				render(definition.StatId)
				return
			end
		end
		if not suppressReplicated then
			render(replicatedStat())
		end
	end)

	if player.Character ~= nil then
		watchCharacter(player.Character)
	end
	player.CharacterAdded:Connect(watchCharacter)
end

return TrainingMuscleHighlightController
