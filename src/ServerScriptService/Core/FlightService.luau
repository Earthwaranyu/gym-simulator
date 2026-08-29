--!strict
--[[
	FlightService — decides who is allowed in the air.

	The server owns permission; the client owns the flying itself. That split is
	deliberate. Roblox gives a client authority over its own character's physics no
	matter what we do, so a server that tried to simulate flight would be fighting
	the owner of the parts it was moving, and a cheater who wanted to hover could do
	it whether or not this file existed. What the server can hold is the *rule* —
	and the rules here exist to protect the PvP hook. The one movement correction the
	server does own is the generated world's safety envelope: a character below the
	walkable ocean or beyond its perimeter is returned to the nearest legal point.

	Permission is published as a character attribute rather than a remote so every
	client can see who may fly, which is what lets an attacker read the situation.

	Grounding on damage is the important part. Flight that could be triggered the
	instant a fight started would gut the training interrupt: knocking someone off a
	machine only costs them something if you can then follow up. Taking a hit
	grounds you for the same window as the stagger, so one punch buys exactly one
	opening.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local MovementConfig = require(ReplicatedStorage.Modules.MovementConfig)
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)

-- Permission is re-evaluated on a slow tick as well as on events, because total
-- power creeps upward continuously and nothing fires when it crosses the line.
local REFRESH_INTERVAL = 1
local SAFETY_INTERVAL = 0.1

local FlightService = {
	Name = "FlightService",
	Priority = 35,
}

local StatService: any = nil
local TrainingService: any = nil

local groundedUntil: { [Player]: number } = {}

function FlightService:Init()
	StatService = Loader.Get("StatService")
	TrainingService = Loader.Get("TrainingService")
end

--[[
	Grounds a player for the combat-lock window. CombatService calls this on every
	hit that lands, alongside the training interrupt.
]]
function FlightService:Ground(player: Player)
	groundedUntil[player] = os.clock() + MovementConfig.FLIGHT_COMBAT_LOCK
	self:_refresh(player)
end

function FlightService:IsGrounded(player: Player): boolean
	return os.clock() < (groundedUntil[player] or 0)
end

--[[
	Whether a player may currently be in the air: strong enough, not just hit, not
	locked to a machine, and alive.
]]
function FlightService:CanFly(player: Player): boolean
	if self:IsGrounded(player) then
		return false
	end
	if TrainingService:IsTraining(player) then
		return false
	end
	return StatService:GetTotalPower(player) >= MovementConfig.FLIGHT_POWER
end

function FlightService:_refresh(player: Player)
	local character = player.Character
	if character == nil then
		return
	end

	local allowed = self:CanFly(player)
	if character:GetAttribute(MovementConfig.FLIGHT_ATTRIBUTE) ~= allowed then
		character:SetAttribute(MovementConfig.FLIGHT_ATTRIBUTE, allowed)
	end

	-- Losing permission clears the pose here rather than waiting for the client to
	-- report it. The client does drop itself — FlightController watches this same
	-- attribute — but a punched player is exactly the case where trusting them to send
	-- one more message is wrong, and a flier frozen mid-cruise while they fall is the
	-- most visible bug this system could have.
	if not allowed and character:GetAttribute(FlightConfig.STATE_ATTRIBUTE) ~= nil then
		character:SetAttribute(FlightConfig.STATE_ATTRIBUTE, nil)
	end
end

function FlightService:_enforceWorldBounds(player: Player)
	local character = player.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if root == nil or not root:IsA("BasePart") or humanoid == nil or humanoid.Health <= 0 then
		return
	end

	local at = root.Position
	local minimumY = MovementConfig.WATER_SURFACE_Y + MovementConfig.FLIGHT_WATER_CLEARANCE
	local centerX = MovementConfig.FLIGHT_WORLD_CENTER_X
	local centerZ = MovementConfig.FLIGHT_WORLD_CENTER_Z
	local minX = centerX - MovementConfig.FLIGHT_WORLD_HALF_WIDTH
	local maxX = centerX + MovementConfig.FLIGHT_WORLD_HALF_WIDTH
	local minZ = centerZ - MovementConfig.FLIGHT_WORLD_HALF_DEPTH
	local maxZ = centerZ + MovementConfig.FLIGHT_WORLD_HALF_DEPTH
	local corrected =
		Vector3.new(math.clamp(at.X, minX, maxX), math.max(at.Y, minimumY), math.clamp(at.Z, minZ, maxZ))
	if (corrected - at).Magnitude <= 0.05 then
		return
	end

	root.CFrame += corrected - at
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
end

--[[
	Publishes which flight silhouette a player is in, so every other client can pose
	them.

	The permission attribute has always been here; this is the other half. Permission
	says who *may* fly, and until now nothing said who *is* — so FlightController could
	animate its own body and no one else's, which is the wrong way round for the one
	movement mode people spend minutes at a time watching each other do.

	Reported by the client rather than derived here, on the same reasoning as sprint
	and dash: Roblox hands a client authority over its own character's physics whatever
	the server does, so the server cannot know the difference between flying and falling
	without simulating flight itself. What it can do is publish the claim, and refuse to
	publish one from somebody it has grounded — which is what keeps a punched player from
	staying in a cruise pose while they drop.
]]
function FlightService:SetFlightState(player: Player, state: string?)
	local character = player.Character
	if character == nil then
		return
	end

	local resolved = state
	if resolved ~= nil and (not self:CanFly(player) or FlightConfig.Get(resolved) == nil) then
		-- An unknown pose id or a grounded player both mean "not flying", rather than
		-- meaning "leave whatever was there". A stale pose is the one outcome worse
		-- than no pose: the body keeps flying on every other screen after it has fallen.
		resolved = nil
	end

	if character:GetAttribute(FlightConfig.STATE_ATTRIBUTE) == resolved then
		return
	end
	character:SetAttribute(FlightConfig.STATE_ATTRIBUTE, resolved)
end

function FlightService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		groundedUntil[player] = nil
	end)

	-- Same budget as SprintChanged and DashChanged. A human reports a band change a
	-- handful of times per flight; eight a second is far more than the bands can
	-- genuinely cross.
	Net.BindEvent("FlightChanged", 8, function(player: Player, state: any)
		if state ~= nil and type(state) ~= "string" then
			return
		end
		self:SetFlightState(player, state)
	end)

	-- Mounting and dismounting a machine both change the answer immediately, and
	-- waiting up to a second to publish that reads as the key not working.
	TrainingService.TrainingChanged:Connect(function(player: Player)
		self:_refresh(player)
	end)

	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				self:_refresh(player)
			end
			task.wait(REFRESH_INTERVAL)
		end
	end)

	task.spawn(function()
		while true do
			for _, player in Players:GetPlayers() do
				self:_enforceWorldBounds(player)
			end
			task.wait(SAFETY_INTERVAL)
		end
	end)

	-- A fresh character starts with no attribute at all, so publish once as soon as
	-- one appears rather than leaving a second of ambiguity.
	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			groundedUntil[player] = nil
			self:_refresh(player)
		end)
	end)
end

return FlightService
