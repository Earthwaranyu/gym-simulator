--!strict
--[[
	MuscleController — smooths every character's growth on this client.

	The server writes target scales into each character's MuscleScales folder; this
	lerps the actual meshes toward them so a player swells visibly over a set instead
	of popping between sizes each time the server refreshes.

	Every client runs the same maths against the same replicated NumberValues, so all
	players see the same bodies. Nothing here is authoritative — a tampered client can
	only lie to itself about how big someone looks.

	Known limitation: this resizes MeshParts without re-fitting their Motor6D joints,
	so at extreme scales limbs pull away from their sockets. Joint correction and
	collision sanity are checklist item 28.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Formulas = require(ReplicatedStorage.Modules.Formulas)

local FOLDER_NAME = "MuscleScales"
-- Higher converges faster. Framerate-independent via the exponential below.
local LERP_RATE = 4

local MuscleController = {
	Name = "MuscleController",
	Priority = 40,
}

-- Original mesh sizes, captured before we ever resize anything.
local baseSizes: { [BasePart]: Vector3? } = {}

local function getBaseSize(part: BasePart): Vector3
	local stored = baseSizes[part]
	if stored ~= nil then
		return stored
	end

	local captured = part.Size
	baseSizes[part] = captured
	return captured
end

local function applyCharacter(character: Model, deltaTime: number)
	local folder = character:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		return
	end

	-- Exponential smoothing, so the rate is the same at 30fps and 240fps.
	local alpha = 1 - math.exp(-LERP_RATE * deltaTime)

	for _, value in folder:GetChildren() do
		if not value:IsA("NumberValue") then
			continue
		end

		local part = character:FindFirstChild(value.Name)
		if part == nil or not part:IsA("BasePart") then
			continue
		end

		local scale = math.clamp(value.Value, 1, Formulas.MAX_MUSCLE_SCALE)
		local target = getBaseSize(part) * scale

		if (part.Size - target).Magnitude > 0.001 then
			part.Size = part.Size:Lerp(target, alpha)
		end
	end
end

function MuscleController:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character == nil then
			return
		end
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				baseSizes[part] = nil
			end
		end
	end)

	RunService.RenderStepped:Connect(function(deltaTime: number)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character ~= nil then
				applyCharacter(character, deltaTime)
			end
		end
	end)
end

return MuscleController
