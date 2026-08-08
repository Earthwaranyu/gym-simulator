--!strict
--[[
	FlightController — the "fly" rung of the movement ladder.

	Q takes off and lands, once the server has said this character may. WASD steers
	relative to the camera, Space climbs, and Control drops. Shift is reserved for
	Legs-scaled sprinting while grounded. The server publishes
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
local Net = require(ReplicatedStorage.Modules.Net)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local MovementConfig = require(ReplicatedStorage.Modules.MovementConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local FlightController = {
	Name = "FlightController",
	Priority = 8,
}

local flying = false
local character: Model? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local mover: LinearVelocity? = nil
local orienter: AlignOrientation? = nil
local attachment: Attachment? = nil
local velocity = Vector3.zero
local lastJumpTapAt = 0

local ToastController: any = nil
local ProfileController: any = nil

function FlightController:Init()
	ToastController = Loader.Get("ToastController")
	ProfileController = Loader.Get("ProfileController")
end

--[[
	Level flight speed for this player's Legs.

	Read every frame rather than cached on takeoff, so a rep landed mid-flight
	shows up immediately — which is the whole point of Legs being the traversal
	stat. Falls back to zero Legs before the first profile push, which is the floor
	and still faster than running.
]]
local function flightSpeed(): number
	local data = ProfileController:Get()
	local legs = if data ~= nil then (data.Stats.Legs or 0) else 0
	return Formulas.FlightSpeed(legs)
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
	if orienter ~= nil then
		orienter:Destroy()
		orienter = nil
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

	-- Without this the rig tumbles. PlatformStand switches off the humanoid's own
	-- balancing, and nothing else damps angular velocity — so the first clipped corner
	-- or leftover spin from a jump sets the character rotating forever, which is the
	-- "flying animation keeps spinning" bug. AlignOrientation replaces the balance the
	-- humanoid stopped providing.
	local orient = Instance.new("AlignOrientation")
	orient.Name = "FlightOrientation"
	orient.Attachment0 = point
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.RigidityEnabled = false
	orient.Responsiveness = MovementConfig.FLIGHT_ORIENT_RESPONSIVENESS
	orient.MaxTorque = math.huge
	orient.CFrame = part.CFrame
	orient.Parent = part

	attachment = point
	mover = force
	orienter = orient
	velocity = part.AssemblyLinearVelocity
	flying = true
	Net.Event("SprintChanged"):FireServer(false)

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
	The direction the player is asking to go, in world space.

	Flight follows where the camera is *looking*, pitch included: point down and hold
	forward and you dive. This used to flatten the camera to the horizon, so the only
	way down was the descend key and flying felt like driving a hovercraft — you could
	aim at a sky deck and still travel level underneath it.

	Mobile keeps working because the thumbstick is recovered rather than replaced:
	`MoveDirection` is decomposed against the camera's flattened basis to get "how much
	forward, how much right", and those two numbers are then re-applied to the camera's
	full 3D basis.
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

	local look = camera.CFrame.LookVector
	local right = camera.CFrame.RightVector

	-- The camera's basis with pitch removed, which is the space MoveDirection is in.
	local flatLook = Vector3.new(look.X, 0, look.Z)
	local flatRight = Vector3.new(right.X, 0, right.Z)
	flatLook = if flatLook.Magnitude > 1e-4 then flatLook.Unit else Vector3.new(0, 0, -1)
	flatRight = if flatRight.Magnitude > 1e-4 then flatRight.Unit else Vector3.new(1, 0, 0)

	local forwardAmount = move:Dot(flatLook)
	local rightAmount = move:Dot(flatRight)

	local vertical = 0
	if UserInputService:IsKeyDown(MovementConfig.ASCEND_KEY) then
		vertical += 1
	end
	if UserInputService:IsKeyDown(MovementConfig.DESCEND_KEY) then
		vertical -= 1
	end

	local speed = flightSpeed()

	-- Re-applied to the full basis, so forward means "where I am looking".
	local direction = look * forwardAmount + right * rightAmount
	if direction.Magnitude > 1e-4 then
		direction = direction.Unit * speed
	else
		direction = Vector3.zero
	end

	return direction + Vector3.new(0, vertical * speed * MovementConfig.FLIGHT_CLIMB_RATIO, 0)
end

local function constrainToWorld(part: BasePart, requested: Vector3): Vector3
	local at = part.Position
	local x, y, z = requested.X, requested.Y, requested.Z
	local minRootY = MovementConfig.WATER_SURFACE_Y + MovementConfig.FLIGHT_WATER_CLEARANCE
	local halfWidth = MovementConfig.FLIGHT_WORLD_HALF_WIDTH
	local halfDepth = MovementConfig.FLIGHT_WORLD_HALF_DEPTH
	local corrected = Vector3.new(
		math.clamp(at.X, -halfWidth, halfWidth),
		math.max(at.Y, minRootY),
		math.clamp(at.Z, -halfDepth, halfDepth)
	)
	if (corrected - at).Magnitude > 1e-3 then
		part.CFrame += corrected - at
		part.AssemblyLinearVelocity = Vector3.zero
		at = corrected
	end

	-- Collision stops the rig physically; this removes the downward force just before
	-- contact so LinearVelocity cannot keep pressing the avatar through the water seam.
	if at.Y <= minRootY + 1.5 and y < 0 then
		y = 0
	end

	if (at.X <= -halfWidth + 2 and x < 0) or (at.X >= halfWidth - 2 and x > 0) then
		x = 0
	end

	if (at.Z <= -halfDepth + 2 and z < 0) or (at.Z >= halfDepth - 2 and z > 0) then
		z = 0
	end

	return Vector3.new(x, y, z)
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
	velocity = constrainToWorld(part, velocity)
	force.VectorVelocity = velocity

	-- Face the way you are moving, upright. Held level rather than banked into the
	-- dive: a rig with no flight animation looks like a falling body when pitched, and
	-- an upright one reads as flight even while descending.
	local orient = orienter
	if orient ~= nil then
		local heading = Vector3.new(velocity.X, 0, velocity.Z)
		if heading.Magnitude > 1 then
			orient.CFrame = CFrame.lookAt(Vector3.zero, heading.Unit)
		else
			-- Hovering: keep whatever heading we had, just level. Deriving it from the
			-- current CFrame rather than leaving it alone is what stops a residual
			-- tilt from persisting for the whole flight.
			local current = part.CFrame.LookVector
			local flat = Vector3.new(current.X, 0, current.Z)
			if flat.Magnitude > 1e-3 then
				orient.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
			end
		end
	end
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
		if processed then
			return
		end

		if input.KeyCode == MovementConfig.TOGGLE_KEY then
			self:Toggle()
			return
		end

		if input.KeyCode == MovementConfig.SPRINT_KEY and not flying then
			Net.Event("SprintChanged"):FireServer(true)
			return
		end

		-- Double-tap jump to take off. Only while grounded: in the air Space is
		-- already the climb key, and turning a climb into a landing would make
		-- ascending impossible to hold.
		if input.KeyCode == Enum.KeyCode.Space and not flying then
			local now = os.clock()
			if now - lastJumpTapAt <= MovementConfig.DOUBLE_TAP_SECONDS then
				lastJumpTapAt = 0
				self:Toggle()
			else
				lastJumpTapAt = now
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == MovementConfig.SPRINT_KEY then
			Net.Event("SprintChanged"):FireServer(false)
		end
	end)

	RunService.Heartbeat:Connect(function(delta: number)
		self:_step(delta)
	end)
end

return FlightController
