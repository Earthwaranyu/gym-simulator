--!strict
--[[
	FlightController — the "fly" rung of the movement ladder.

	Q takes off and lands, once the server has said this character may. WASD steers
	relative to the camera, Space climbs, Shift drops. The server publishes
	permission as a character attribute (see FlightService); this file never asks for
	it and never argues when it is taken away mid-flight — losing permission drops
	you, which is exactly what happens when somebody punches you out of the sky.

	Flight is held by a LinearVelocity on the root rather than by moving the character
	directly. That keeps it inside the physics engine, so a flying player still
	collides with platforms, still gets knocked about, and cannot phase through the
	world — and it means letting go simply stops forcing a velocity, and gravity
	takes over on its own.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local MovementConfig = require(ReplicatedStorage.Modules.MovementConfig)

local FlightController = {
	Name = "FlightController",
	Priority = 8,
}

local flying = false
local character: Model? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local mover: LinearVelocity? = nil
local attachment: Attachment? = nil
local velocity = Vector3.zero

local ToastController: any = nil

function FlightController:Init()
	ToastController = Loader.Get("ToastController")
end

local function isAllowed(): boolean
	local model = character
	if model == nil or model.Parent == nil then
		return false
	end
	return model:GetAttribute(MovementConfig.FLIGHT_ATTRIBUTE) == true
end

--[[
	Stops flying and hands the body back to the humanoid. Safe to call at any time,
	including when never airborne.
]]
function FlightController:Stop()
	flying = false
	velocity = Vector3.zero

	if mover ~= nil then
		mover:Destroy()
		mover = nil
	end
	if attachment ~= nil then
		attachment:Destroy()
		attachment = nil
	end
	if humanoid ~= nil and humanoid.Parent ~= nil then
		humanoid.PlatformStand = false
	end
end

function FlightController:IsFlying(): boolean
	return flying
end

function FlightController:_takeOff()
	local model = character
	local part = root
	if model == nil or part == nil or not isAllowed() then
		return
	end

	local point = Instance.new("Attachment")
	point.Name = "FlightAttachment"
	point.Parent = part

	local force = Instance.new("LinearVelocity")
	force.Name = "FlightVelocity"
	force.Attachment0 = point
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.MaxForce = math.huge
	force.VectorVelocity = Vector3.zero
	force.Parent = part

	attachment = point
	mover = force
	velocity = part.AssemblyLinearVelocity
	flying = true

	-- The humanoid would otherwise keep trying to walk, and fight the velocity every
	-- frame while standing on nothing.
	if humanoid ~= nil then
		humanoid.PlatformStand = true
	end
end

function FlightController:Toggle()
	if flying then
		self:Stop()
		return
	end

	if not isAllowed() then
		-- Deliberately vague about which rule stopped them: power, a punch, or being
		-- bolted to a machine all read the same from here, and the server is the only
		-- side that knows which.
		ToastController:Show(`Flight needs {NumberFormat.Format(MovementConfig.FLIGHT_POWER)} power`)
		return
	end

	self:_takeOff()
end

--[[
	The direction the player is asking to go, in world space, from camera-relative
	input. Returns a unit vector, or zero when they are asking to hover.
]]
local function inputDirection(): Vector3
	local camera = workspace.CurrentCamera
	if camera == nil then
		return Vector3.zero
	end

	-- MoveDirection already folds WASD and the mobile thumbstick into one
	-- camera-relative vector, so steering costs no input handling of its own.
	local humanoidObject = humanoid
	local move = if humanoidObject ~= nil then humanoidObject.MoveDirection else Vector3.zero

	local vertical = 0
	if UserInputService:IsKeyDown(MovementConfig.ASCEND_KEY) then
		vertical += 1
	end
	if UserInputService:IsKeyDown(MovementConfig.DESCEND_KEY) then
		vertical -= 1
	end

	local direction = Vector3.new(move.X, 0, move.Z)
	if direction.Magnitude > 0 then
		direction = direction.Unit * MovementConfig.FLIGHT_SPEED
	end
	return direction + Vector3.new(0, vertical * MovementConfig.FLIGHT_CLIMB_SPEED, 0)
end

function FlightController:_step(delta: number)
	if not flying then
		return
	end

	local force = mover
	local part = root
	if force == nil or part == nil or part.Parent == nil or not isAllowed() then
		self:Stop()
		return
	end

	-- Ease toward the requested velocity rather than snapping to it, so a change of
	-- direction carries a little momentum instead of reading as teleporting.
	local blend = math.min(1, MovementConfig.FLIGHT_ACCELERATION * delta)
	velocity = velocity:Lerp(inputDirection(), blend)
	force.VectorVelocity = velocity
end

function FlightController:_bind(model: Model)
	self:Stop()

	character = model
	root = model:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	humanoid = model:FindFirstChildOfClass("Humanoid")

	model:GetAttributeChangedSignal(MovementConfig.FLIGHT_ATTRIBUTE):Connect(function()
		if flying and not isAllowed() then
			self:Stop()
		end
	end)

	local living = humanoid
	if living ~= nil then
		living.Died:Connect(function()
			self:Stop()
		end)
	end
end

function FlightController:Start()
	local player = Players.LocalPlayer

	if player.Character ~= nil then
		self:_bind(player.Character)
	end
	player.CharacterAdded:Connect(function(model: Model)
		self:_bind(model)
	end)
	player.CharacterRemoving:Connect(function()
		self:Stop()
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= MovementConfig.TOGGLE_KEY then
			return
		end
		self:Toggle()
	end)

	RunService.Heartbeat:Connect(function(delta: number)
		self:_step(delta)
	end)
end

return FlightController
