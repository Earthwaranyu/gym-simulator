--!strict
--[[
	CombatController — attack input and target selection.

	Picks a target and sends intent. The server re-validates range, cooldown, stamina,
	and liveness, so the worst a modified client achieves is asking for hits it will
	not get.

	Target selection prefers whoever is closest to where the camera is pointing rather
	than simply nearest, so punching someone in a crowd of trainers hits the one you
	are looking at.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Net = require(ReplicatedStorage.Modules.Net)

local ATTACK_ACTION = "GymSimulatorAttack"
local DEFAULT_ABILITY = "Punch"
local TARGET_RANGE = 12
-- Only consider players within this cone of where the camera points.
local MIN_AIM_DOT = 0.35

local CombatController = {
	Name = "CombatController",
	Priority = 70,
}

-- (feedback) — Hit, Hurt, Blocked, or Rejected payloads from the server.
CombatController.Feedback = Signal.new()

local function getRoot(character: Model?): BasePart?
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

local function isAlive(character: Model?): boolean
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[
	The player the local character is most plausibly attacking, or nil.
]]
function CombatController:FindTarget(): Player?
	local localPlayer = Players.LocalPlayer
	local myRoot = getRoot(localPlayer.Character)
	if myRoot == nil or not isAlive(localPlayer.Character) then
		return nil
	end

	local camera = Workspace.CurrentCamera
	local aim = if camera ~= nil then camera.CFrame.LookVector else myRoot.CFrame.LookVector

	local best: Player? = nil
	local bestScore = -math.huge

	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end

		local otherRoot = getRoot(other.Character)
		if otherRoot == nil or not isAlive(other.Character) then
			continue
		end

		local offset = otherRoot.Position - myRoot.Position
		local distance = offset.Magnitude
		if distance > TARGET_RANGE or distance <= 0 then
			continue
		end

		local dot = offset.Unit:Dot(aim)
		if dot < MIN_AIM_DOT then
			continue
		end

		-- Favour well-aimed targets, then closer ones.
		local score = dot - distance / TARGET_RANGE * 0.5
		if score > bestScore then
			bestScore = score
			best = other
		end
	end

	return best
end

function CombatController:Attack()
	local target = self:FindTarget()
	if target == nil then
		return
	end
	Net.Event("AbilityActivate"):FireServer(DEFAULT_ABILITY, target)
end

function CombatController:Init()
	Net.Event("CombatFeedback").OnClientEvent:Connect(function(payload: any)
		CombatController.Feedback:Fire(payload)
	end)
end

function CombatController:Start()
	ContextActionService:BindAction(ATTACK_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			self:Attack()
		end
		return Enum.ContextActionResult.Pass
	end, true, Enum.KeyCode.F, Enum.KeyCode.ButtonX)

	ContextActionService:SetTitle(ATTACK_ACTION, "Punch")
end

return CombatController
