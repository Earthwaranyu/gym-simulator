--!strict
--[[
	FlightController — the "fly" rung of the movement ladder.

	Double-tapping Space takes off and lands, once the server has said this character
	may — it is the only way in and out of the air, because Q became the dash. WASD
	steers relative to the camera, Space climbs, and Control drops. Shift toggles
	Legs-scaled sprinting while grounded. The server publishes
	permission as a character attribute (see FlightService); this file never asks for
	it and never argues when it is taken away mid-flight — losing permission drops
	you, which is exactly what happens when somebody punches you out of the sky.

	Two of those inputs are the same key doing different jobs, and the tap detector
	below is what keeps them apart: held, Space climbs; tapped twice, it lands.

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
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)
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
local sprinting = false
-- When the current Space press began, or 0 if the key is up. Paired with the time of
-- the last completed *tap*, these two are the whole double-tap detector.
local spaceHeldSince = 0
local lastSpaceTapAt = 0
-- The last silhouette reported to the server, so only a genuine band change crosses
-- the wire. Nil means "on the ground", which is also what is published on landing.
local reportedState: string? = nil
-- Heading last frame, and the eased bank angle. Bank comes from how fast the heading
-- is turning, so it needs the previous frame to compare against, and it is eased
-- rather than tracked so a twitchy camera does not make the body flicker.
local lastHeading: Vector3? = nil
local bankDegrees = 0

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

--[[
	Turns sprinting on or off, telling the server only when it actually changed.

	Sprint is a toggle rather than a held key, so the client owns a piece of state the
	server also keeps (CombatService applies the speed). Guarding on change keeps one
	keypress to one remote call instead of one per frame, and keeps the two in step.
]]
local function setSprint(value: boolean)
	if sprinting == value then
		return
	end
	sprinting = value
	Net.Event("SprintChanged"):FireServer(value)
end

--[[
	Tells the server which flight silhouette we are in, when it changes.

	Only band changes are sent. The exact speed is not: a float republished as it
	changed would be a property write to every client in the server, every frame, for
	every player in the air. The band is all anybody else needs, because they are
	blending toward a pose rather than steering it — and this client never reads its own
	attribute back, so the coarseness costs the person actually flying nothing.
]]
local function setFlightState(state: string?)
	if reportedState == state then
		return
	end
	reportedState = state
	Net.Event("FlightChanged"):FireServer(state)
end

local function isAllowed(): boolean
	local model = character
	if model == nil or model.Parent == nil then
		return false
	end
	return model:GetAttribute(MovementConfig.FLIGHT_ATTRIBUTE) == true
end

--[[
	Where the root may not descend past, at a given spot.

	The sea used to be the only floor flight knew about, which is wrong everywhere the
	world is land. On a city district the solid ground is a four-stud slab topping out at
	y = 1, and every surface above it — the campus floor, the courts, the training pads,
	each machine's mat — is CanCollide=false decoration. Flight's mover is a
	LinearVelocity with an infinite MaxForce and it flies with PlatformStand set, so the
	humanoid does no standing correction: holding descend simply pushed the avatar
	through that slab, and the water clamp then parked it at y -4.5, five studs under the
	district. Inside a sealed gym there is nothing below to land on and nothing to walk
	out through.

	So ask the world what is underneath instead of assuming. The sea clamp stays as the
	answer for when the ray finds nothing, which is what happens out over open water.
]]
local function floorBelow(part: BasePart, model: Model, hum: Humanoid?): number
	local waterFloor = MovementConfig.WATER_SURFACE_Y + MovementConfig.FLIGHT_WATER_CLEARANCE

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true
	-- Only surfaces the player could actually stand on. A raycast hits CanCollide=false
	-- parts unless told otherwise, and the world is full of them — court markings,
	-- machine mats, the ropes on a battle-rope rig — so without this, flight would stop
	-- against decoration and leave the avatar hovering over a floor mat.
	params.RespectCanCollide = true

	-- From a little above the root, so a root that has already sunk into geometry still
	-- finds the surface it should be standing on rather than starting below it.
	local from = part.Position + Vector3.new(0, 6, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -4096, 0), params)
	if hit == nil then
		return waterFloor
	end

	local standing = hit.Position.Y + (if hum ~= nil then hum.HipHeight else 2) + part.Size.Y / 2
	return math.max(waterFloor, standing)
end

--[[
	Stops flying and hands the body back to the humanoid. Safe to call at any time,
	including when never airborne.
]]
function FlightController:Stop()
	flying = false
	velocity = Vector3.zero
	lastHeading = nil
	bankDegrees = 0
	-- Told before anything is torn down. Landing has to reach the other clients even if
	-- the teardown below throws, because the failure mode is a body left cruising on
	-- every screen but this one.
	setFlightState(nil)

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
	-- Put the avatar back on top of the world before handing it to the humanoid.
	--
	-- Landing used to just stop forcing a velocity and let gravity take over, which is
	-- right in the air and useless below the ground: there is nothing under a district
	-- to fall onto, so anyone who got under one stayed there. This costs one raycast on
	-- a keypress and means no landing can strand a player inside the map.
	local part = root
	local model = character
	if part ~= nil and part.Parent ~= nil and model ~= nil then
		local floor = floorBelow(part, model, humanoid)
		if part.Position.Y < floor then
			part.CFrame += Vector3.new(0, floor - part.Position.Y, 0)
			part.AssemblyLinearVelocity = Vector3.zero
		end
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
	-- You are not running any more. Left set, the toggle would still read as "on" when
	-- you landed, and Shift would appear to do nothing the first time you pressed it.
	setSprint(false)

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
	local minRootY = floorBelow(part, part.Parent :: Model, humanoid)
	local centerX = MovementConfig.FLIGHT_WORLD_CENTER_X
	local centerZ = MovementConfig.FLIGHT_WORLD_CENTER_Z
	local halfWidth = MovementConfig.FLIGHT_WORLD_HALF_WIDTH
	local halfDepth = MovementConfig.FLIGHT_WORLD_HALF_DEPTH
	local minX, maxX = centerX - halfWidth, centerX + halfWidth
	local minZ, maxZ = centerZ - halfDepth, centerZ + halfDepth
	local corrected =
		Vector3.new(math.clamp(at.X, minX, maxX), math.max(at.Y, minRootY), math.clamp(at.Z, minZ, maxZ))
	if (corrected - at).Magnitude > 1e-3 then
		part.CFrame += corrected - at
		part.AssemblyLinearVelocity = Vector3.zero
		at = corrected
	end

	-- Cut the downward force just before contact so an infinite-MaxForce mover cannot
	-- keep pressing the avatar into whatever it has landed on. The margin used to be
	-- 1.5, which was sized for the water seam; against a real floor that left the
	-- player hovering more than a stud up, so it is tight enough now to settle.
	if at.Y <= minRootY + 0.4 and y < 0 then
		y = 0
	end

	if (at.X <= minX + 2 and x < 0) or (at.X >= maxX - 2 and x > 0) then
		x = 0
	end

	if (at.Z <= minZ + 2 and z < 0) or (at.Z >= maxZ - 2 and z > 0) then
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

	-- Face the way you are moving, pitched into the climb and banked into the turn.
	--
	-- This used to be held rigidly level, and the comment here said why: a rig with no
	-- flight animation looks like a falling body when pitched, so upright was the least
	-- bad option. FlightConfig is what removed that constraint — there is a flight pose
	-- now, and a body that lies along its own velocity with a fist out in front reads as
	-- flying at any angle. Attitude and silhouette are separate halves of the same
	-- effect: this sets how the character is held, the pose sets what shape they hold.
	local orient = orienter
	local topSpeed = flightSpeed()
	local speed = velocity.Magnitude
	if orient ~= nil then
		local heading = Vector3.new(velocity.X, 0, velocity.Z)
		if heading.Magnitude > 1 then
			local flat = heading.Unit

			-- Bank from how fast the heading is swinging, not from the input: a player
			-- turning by dragging the camera and one turning by holding A are doing the
			-- same thing to the body, and only the resulting heading knows that.
			local previous = lastHeading
			local turnRate = 0
			if previous ~= nil and delta > 1e-4 then
				-- Signed by which side the turn went to, so a left turn drops the left
				-- shoulder. The Y of the cross product is the sign of the sweep.
				local sweep = previous:Cross(flat).Y
				local angle = math.asin(math.clamp(sweep, -1, 1))
				turnRate = angle / delta
			end
			lastHeading = flat

			local targetBank = Formulas.FlightBank(turnRate)
			-- Eased toward, never snapped to. Turn rate is noisy frame to frame and an
			-- un-eased bank reads as the character shivering.
			bankDegrees += (targetBank - bankDegrees) * math.min(
				1,
				MovementConfig.FLIGHT_BANK_RESPONSIVENESS * delta
			)

			local pitchDegrees = Formulas.FlightPitch(velocity.Y, speed)
			orient.CFrame = CFrame.lookAt(Vector3.zero, flat)
				* CFrame.Angles(math.rad(pitchDegrees), 0, math.rad(bankDegrees))
		else
			-- Hovering: keep whatever heading we had, just level. Deriving it from the
			-- current CFrame rather than leaving it alone is what stops a residual
			-- tilt from persisting for the whole flight.
			lastHeading = nil
			bankDegrees += (0 - bankDegrees) * math.min(1, MovementConfig.FLIGHT_BANK_RESPONSIVENESS * delta)
			local current = part.CFrame.LookVector
			local flat = Vector3.new(current.X, 0, current.Z)
			if flat.Magnitude > 1e-3 then
				orient.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
			end
		end
	end

	-- Published last, from the speed this frame actually settled on rather than from the
	-- one that was requested — the eased velocity is what the body is doing, and it is
	-- what every other client will be posing.
	setFlightState(Formulas.FlightBand(speed, topSpeed))
end

function FlightController:_bind(model: Model)
	self:Stop()

	-- CombatService clears sprint for every new character. Mirror it rather than
	-- announce it: if the client stayed "on" after a respawn, the first Shift press
	-- would toggle it off and read as a dead key.
	sprinting = false
	spaceHeldSince = 0
	lastSpaceTapAt = 0

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

		if input.KeyCode == MovementConfig.SPRINT_KEY and not flying then
			setSprint(not sprinting)
			return
		end

		-- Double-tap jump to take off, and again to land. The second tap fires on the
		-- key going down, because waiting for the release would make the gesture feel
		-- late; the first tap only counts if it was short (see InputEnded), which is
		-- what stops a held climb from arming a landing.
		if input.KeyCode == Enum.KeyCode.Space then
			local now = os.clock()
			if lastSpaceTapAt > 0 and now - lastSpaceTapAt <= MovementConfig.DOUBLE_TAP_SECONDS then
				spaceHeldSince = 0
				lastSpaceTapAt = 0
				self:Toggle()
			else
				spaceHeldSince = now
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode ~= Enum.KeyCode.Space then
			return
		end

		-- A quick press arms the second half of a double-tap. A long one — the ascend
		-- control, or a held jump — disarms it, so climbing can never turn into
		-- falling out of the sky.
		local now = os.clock()
		local wasTap = spaceHeldSince > 0 and now - spaceHeldSince <= MovementConfig.TAP_HOLD_SECONDS
		lastSpaceTapAt = if wasTap then now else 0
		spaceHeldSince = 0
	end)

	RunService.Heartbeat:Connect(function(delta: number)
		self:_step(delta)
	end)
end

return FlightController
