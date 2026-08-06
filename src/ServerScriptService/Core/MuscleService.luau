--!strict
--[[
	MuscleService — turns stats into visible size.

	Per CLAUDE.md, avatar scaling is driven by NumberValue instances inside the
	character model. The server owns those values; they replicate automatically, and
	every client lerps its own meshes toward them (see MuscleController). That split
	keeps the server authoritative over how big someone is, while the smoothing costs
	the server nothing.

	Which parts a stat inflates, and how strongly, is declared in StatConfig.BodyScales
	— so a new stat grows the body correctly without this file changing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local FOLDER_NAME = "MuscleScales"
-- Stats change several times a second while training; the visual does not need to.
local REFRESH_SECONDS = 0.5

local MuscleService = {
	Name = "MuscleService",
	Priority = 20,
}

local StatService: any = nil

function MuscleService:Init()
	StatService = Loader.Get("StatService")
end

local function getFolder(character: Model): Folder
	local existing = character:FindFirstChild(FOLDER_NAME)
	if existing ~= nil and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = character
	return folder
end

local function getValue(folder: Folder, partName: string): NumberValue
	local existing = folder:FindFirstChild(partName)
	if existing ~= nil and existing:IsA("NumberValue") then
		return existing
	end

	local value = Instance.new("NumberValue")
	value.Name = partName
	value.Value = 1
	value.Parent = folder
	return value
end

--[[
	Computes every body part's target scale for a player.

	A part driven by more than one stat (UpperTorso takes both Chest and Back) takes
	the largest contribution rather than the product, so stacking stats cannot compound
	into a runaway size.
]]
function MuscleService:ComputeScales(player: Player): { [string]: number }
	local scales: { [string]: number } = {}

	for _, definition in StatConfig.List do
		local statValue = StatService:GetStat(player, definition.Id)

		for partName, weight in definition.BodyScales do
			local scale = Formulas.MuscleScale(statValue, weight)
			if scales[partName] == nil or scale > scales[partName] then
				scales[partName] = scale
			end
		end
	end

	return scales
end

--[[
	Writes the current target scales into the character. Cheap enough to call on a
	timer: it only touches NumberValues whose value actually moved, so unchanged
	parts cost no replication.
]]
function MuscleService:Refresh(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local folder = getFolder(character)

	for partName, scale in self:ComputeScales(player) do
		local value = getValue(folder, partName)
		if math.abs(value.Value - scale) > 0.001 then
			value.Value = scale
		end
	end
end

function MuscleService:Start()
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			-- Populate immediately so a respawning player is not briefly tiny.
			task.defer(function()
				self:Refresh(player)
			end)
		end)
	end)

	task.spawn(function()
		while true do
			task.wait(REFRESH_SECONDS)
			for _, player in Players:GetPlayers() do
				self:Refresh(player)
			end
		end
	end)
end

return MuscleService
