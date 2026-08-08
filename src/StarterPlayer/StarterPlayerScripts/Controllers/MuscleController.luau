--!strict
--[[
	MuscleController — smooths every character's growth on this client.

	Shape comes from `PhysiqueConfig`: this file decides *when* a part reaches its
	target size, that file decides what that size looks like per axis.

	The server writes target scales into each character's MuscleScales folder; this
	lerps the actual meshes toward them so a player swells visibly over a set instead
	of popping between sizes each time the server refreshes.

	Every client runs the same maths against the same replicated NumberValues, so all
	players see the same bodies. Nothing here is authoritative — a tampered client can
	only lie to itself about how big someone looks.

	Resizing alone is not enough: a Motor6D keeps its offset from each part's centre, so
	growing a limb without re-seating its joints leaves arms visibly detached from
	shoulders. Both offsets are rescaled from cached originals, and hip height tracks
	leg growth so characters stand on the floor instead of sinking into it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Formulas = require(ReplicatedStorage.Modules.Formulas)
local PhysiqueConfig = require(ReplicatedStorage.Modules.PhysiqueConfig)

local FOLDER_NAME = "MuscleScales"
-- Higher converges faster. Framerate-independent via the exponential below.
local LERP_RATE = 4

local MuscleController = {
	Name = "MuscleController",
	Priority = 40,
}

-- Original mesh sizes, captured before we ever resize anything.
local baseSizes: { [BasePart]: Vector3? } = {}
-- Original joint offsets, likewise. Scaling from the current value each frame would
-- compound the error until limbs drifted off entirely.
local baseJoints: { [Motor6D]: { c0: CFrame, c1: CFrame }? } = {}
local baseHipHeights: { [Humanoid]: number? } = {}

local function getBaseSize(part: BasePart): Vector3
	local stored = baseSizes[part]
	if stored ~= nil then
		return stored
	end

	local captured = part.Size
	baseSizes[part] = captured
	return captured
end

--[[
	The factor a part has actually grown by, per axis, right now.
]]
local function currentScale(part: BasePart): Vector3
	local base = getBaseSize(part)
	return Vector3.new(part.Size.X / base.X, part.Size.Y / base.Y, part.Size.Z / base.Z)
end

--[[
	Re-seats every joint after its parts have been resized.

	Without this, growing a limb leaves the joint where the original mesh's surface was,
	so arms visibly detach from shoulders at high scale. A Motor6D's C0 and C1 are
	offsets from each part's centre, so both have to scale with the part they belong to
	— position only, since rotating the offset would twist the limb.
]]
local function refitJoints(character: Model)
	for _, descendant in character:GetDescendants() do
		if not descendant:IsA("Motor6D") then
			continue
		end

		local part0 = descendant.Part0
		local part1 = descendant.Part1
		if part0 == nil or part1 == nil then
			continue
		end

		local stored = baseJoints[descendant]
		if stored == nil then
			stored = { c0 = descendant.C0, c1 = descendant.C1 }
			baseJoints[descendant] = stored
		end

		local c0 = (stored :: { c0: CFrame, c1: CFrame }).c0
		local c1 = (stored :: { c0: CFrame, c1: CFrame }).c1

		descendant.C0 = CFrame.new(c0.Position * currentScale(part0)) * (c0 - c0.Position)
		descendant.C1 = CFrame.new(c1.Position * currentScale(part1)) * (c1 - c1.Position)
	end
end

--[[
	Keeps the character standing on the floor rather than sinking into it as legs grow,
	and keeps collisions sane at the top of the scale range.
]]
local function refitHumanoid(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local leg = character:FindFirstChild("LeftUpperLeg")
	if leg == nil or not leg:IsA("BasePart") then
		return
	end

	local stored = baseHipHeights[humanoid]
	if stored == nil then
		stored = humanoid.HipHeight
		baseHipHeights[humanoid] = stored
	end

	humanoid.HipHeight = (stored :: number) * currentScale(leg).Y
end

local function applyCharacter(character: Model, deltaTime: number)
	local folder = character:FindFirstChild(FOLDER_NAME)
	if folder == nil then
		return
	end

	-- Exponential smoothing, so the rate is the same at 30fps and 240fps.
	local alpha = 1 - math.exp(-LERP_RATE * deltaTime)
	local moved = false

	for _, value in folder:GetChildren() do
		if not value:IsA("NumberValue") then
			continue
		end

		local part = character:FindFirstChild(value.Name)
		if part == nil or not part:IsA("BasePart") then
			continue
		end

		-- Clamped here as well as server-side: this is the last line of defence
		-- before a bad value reaches collision geometry.
		local scale = math.clamp(value.Value, 1, Formulas.MAX_MUSCLE_SCALE)

		-- Per axis, not uniform. Scaling a limb evenly makes it longer as well as
		-- thicker, and a body at the old 2.5x uniform cap stopped reading as a person and started
		-- reading as a box. PhysiqueConfig keeps the height weights low and the waist
		-- behind the chest, which is what produces a taper instead of a barrel.
		local axisX, axisY, axisZ = PhysiqueConfig.AxisScale(value.Name, scale)
		local target = getBaseSize(part) * Vector3.new(axisX, axisY, axisZ)

		if (part.Size - target).Magnitude > 0.001 then
			part.Size = part.Size:Lerp(target, alpha)
			moved = true
		end
	end

	-- Only re-seat joints on frames where something actually resized; walking the
	-- descendants of every character every frame would be the expensive part.
	if moved then
		refitJoints(character)
		refitHumanoid(character)
	end
end

function MuscleController:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character == nil then
			return
		end
		for _, descendant in character:GetDescendants() do
			if descendant:IsA("BasePart") then
				baseSizes[descendant] = nil
			elseif descendant:IsA("Motor6D") then
				baseJoints[descendant] = nil
			elseif descendant:IsA("Humanoid") then
				baseHipHeights[descendant] = nil
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
