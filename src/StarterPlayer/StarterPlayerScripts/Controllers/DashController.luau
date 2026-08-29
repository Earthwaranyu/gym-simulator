--!strict
--[[
	DashController — Q, a short burst in the direction you are already asking for.

	The one movement option that is not about crossing the map. Sprint and flight both
	answer "how do I get to the next island"; a dash answers "he is winding up a punch
	and I am standing on a machine". It is short, it is flat, and it is on a cooldown,
	so it closes or opens one gap rather than replacing running.

	Held inside the physics engine, like flight: a LinearVelocity on the root for a
	fifth of a second rather than moving the character directly. A dash that set CFrame
	would go through walls, and the whole point of the gesture is escaping something in
	a room.

	Two rules it inherits rather than invents:

	  * **Permission.** The same character attribute flight reads. A player bolted to a
	    machine or freshly punched cannot dash, for the same reason they cannot fly —
	    if being hit did not pin you in place, interrupting someone's training would
	    cost the attacker nothing.
	  * **Not while flying.** FlightController owns the root's velocity while airborne
	    and re-asserts it every frame; a second mover fighting it would produce a
	    stutter rather than a dash. Flight is already fast, and Legs makes it faster.

	The one thing it cannot do locally is stop shoving people. Two character
	assemblies that collide push each other, and the push is simulated on both
	players' machines — so the server is told when a dash starts and ends, and it
	owns the collision group that makes a dasher pass through the living. See
	DashService.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local MovementConfig = require(ReplicatedStorage.Modules.MovementConfig)

local DashController = {
	Name = "DashController",
	Priority = 9,
}

local character: Model? = nil
local root: BasePart? = nil
local humanoid: Humanoid? = nil
local readyAt = 0
-- Bumped every dash so a burst that has been superseded knows to leave the newer one
-- alone when its own timer finishes.
local generation = 0

local FlightController: any = nil

function DashController:Init()
	FlightController = Loader.Get("FlightController")
end

local function isAllowed(): boolean
	local model = character
	if model == nil or model.Parent == nil then
		return false
	end
	return model:GetAttribute(MovementConfig.FLIGHT_ATTRIBUTE) == true
end

--[[
	Where the dash sends you: where you are steering, or where you face if you are not.

	MoveDirection already folds WASD and the mobile thumbstick into one camera-relative
	vector, so this costs no input handling of its own — the same reason FlightController
	steers off it.
]]
local function dashDirection(part: BasePart): Vector3
	local living = humanoid
	local move = if living ~= nil then living.MoveDirection else Vector3.zero
	local flat = Vector3.new(move.X, 0, move.Z)
	if flat.Magnitude > 1e-3 then
		return flat.Unit
	end

	local facing = part.CFrame.LookVector
	flat = Vector3.new(facing.X, 0, facing.Z)
	return if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
end

function DashController:IsDashing(): boolean
	local part = root
	return part ~= nil and part:FindFirstChild("DashVelocity") ~= nil
end

function DashController:Dash()
	local part = root
	if part == nil or part.Parent == nil or not isAllowed() then
		return
	end
	if FlightController ~= nil and FlightController:IsFlying() then
		return
	end

	local now = os.clock()
	if now < readyAt then
		return
	end
	readyAt = now + MovementConfig.DASH_COOLDOWN

	local existing = part:FindFirstChild("DashVelocity")
	if existing ~= nil then
		existing:Destroy()
	end

	local point = Instance.new("Attachment")
	point.Name = "DashAttachment"
	point.Parent = part

	local force = Instance.new("LinearVelocity")
	force.Name = "DashVelocity"
	force.Attachment0 = point
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	-- Driven on the two horizontal axes only, so the burst leaves gravity alone. Held
	-- on all three, a dash off a ledge hangs in the air like a cartoon before dropping.
	force.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	force.PrimaryTangentAxis = Vector3.xAxis
	force.SecondaryTangentAxis = Vector3.zAxis
	local direction = dashDirection(part) * MovementConfig.DASH_SPEED
	force.PlaneVelocity = Vector2.new(direction.X, direction.Z)
	force.MaxForce = math.huge
	force.Parent = part

	generation += 1
	local mine = generation
	Net.Event("DashChanged"):FireServer(true)
	task.delay(MovementConfig.DASH_SECONDS, function()
		if generation ~= mine then
			return
		end
		if force.Parent ~= nil then
			force:Destroy()
		end
		if point.Parent ~= nil then
			point:Destroy()
		end
		Net.Event("DashChanged"):FireServer(false)
	end)
end

function DashController:Stop()
	-- Bumping first cancels the in-flight timer, which is also the thing that would
	-- have told the server the dash was over — so say so here instead.
	local wasDashing = self:IsDashing()
	generation += 1
	if wasDashing then
		Net.Event("DashChanged"):FireServer(false)
	end
	local part = root
	if part == nil then
		return
	end
	for _, name in { "DashVelocity", "DashAttachment" } do
		local found = part:FindFirstChild(name)
		if found ~= nil then
			found:Destroy()
		end
	end
end

function DashController:_bind(model: Model)
	self:Stop()
	character = model
	root = model:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	humanoid = model:FindFirstChildOfClass("Humanoid")
	readyAt = 0

	local living = humanoid
	if living ~= nil then
		living.Died:Connect(function()
			self:Stop()
		end)
	end
end

function DashController:Start()
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
		if input.KeyCode == MovementConfig.DASH_KEY then
			self:Dash()
		end
	end)
end

return DashController
