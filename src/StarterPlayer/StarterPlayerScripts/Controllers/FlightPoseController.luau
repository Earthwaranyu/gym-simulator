--!strict
--[[
	FlightPoseController — poses a flying body, on everybody you can see.

	The sibling of TrainingPoseController and StrikeController, built the same way and
	for the same reason. The server stamps one attribute on a character; every client
	notices and animates it locally. Nothing about the animation is replicated, because
	it does not need to be — the silhouettes are in FlightConfig and every machine
	already has them, so all that crosses the wire is "she is cruising".

	Before this, flight was the one body state nobody else could see. FlightController
	drove the local player's velocity and orientation and stopped there, so a remote
	flier was a standing avatar sliding through the air on every screen except their
	own. Training poses, punches and guards all solved that years of code ago; flight
	was simply never wired up.

	Two sources, one blend. The local player is posed from its own velocity, read
	straight off FlightController — smooth, immediate, and free. Everybody else is posed
	from the coarse attribute, eased toward. That split is why the attribute can afford
	to be three strings rather than a float: the only person who would notice the
	coarseness is the one who never reads it.

	Runs on PreSimulation for the reason TrainingPoseController's header spells out:
	that is the window after the animator has evaluated and before the world step reads
	the joint transforms. Write later and the property is set but nothing ever sees it.
	That matters more here than anywhere else, because a flying humanoid is on
	PlatformStand and Roblox's own freefall clip is still playing underneath — every
	joint FlightConfig does not name is a joint the animator keeps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)

local FlightPoseController = {
	Name = "FlightPoseController",
	Priority = 6,
}

local IDENTITY: CFrame = CFrame.identity

local FlightController: any = nil
local ProfileController: any = nil

type Entry = {
	-- Resolved once per takeoff rather than per frame: a rig is a few hundred instances
	-- and this runs on every flier on screen, every frame.
	joints: { { name: string, joint: any } },
	-- Where the blend currently sits, 0 at Hover and 1 at Cruise. Eased toward the
	-- target so a body settles into a cruise instead of snapping between silhouettes.
	blend: number,
	-- How far the pose has faded in from the animator's own clip, 0 to 1.
	weight: number,
	-- True once the character has landed and the pose is fading back out.
	releasing: boolean,
	startedAt: number,
}

local active: { [Model]: Entry } = {}

--[[
	Binds every joint FlightConfig drives, once.

	A joint this rig does not have — an R6 elbow — is dropped here rather than checked
	on every frame of every flight.
]]
local function bindJoints(character: Model): { { name: string, joint: any } }
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return {}
	end

	local bound: { { name: string, joint: any } } = {}
	for _, name in FlightConfig.Joints do
		local joint = PosePlayback.FindJoint(character, humanoid.RigType, name)
		if joint ~= nil then
			table.insert(bound, { name = name, joint = joint })
		end
	end
	return bound
end

--[[
	Hands every joint back to whatever owns it next.

	Cleared to identity rather than eased to zero, exactly as StrikeController does:
	whoever writes these joints next — the animator, a training pose, a punch — writes
	over the top on their own next frame, and a joint left holding a flight angle is a
	body still flying after it has landed.
]]
function FlightPoseController:_clear(character: Model)
	local entry = active[character]
	if entry == nil then
		return
	end
	active[character] = nil
	for _, bound in entry.joints do
		if bound.joint.Parent ~= nil then
			bound.joint.Transform = IDENTITY
		end
	end
end

--[[
	How far through the hover-glide-cruise range this character should be posed.

	The local player is asked of its own velocity, which is exact and free. Everybody
	else is read off the replicated band, which is all that was sent.
]]
local function targetBlendFor(character: Model): number?
	local state = character:GetAttribute(FlightConfig.STATE_ATTRIBUTE)
	if type(state) ~= "string" then
		return nil
	end

	if
		character == Players.LocalPlayer.Character
		and FlightController ~= nil
		and FlightController:IsFlying()
	then
		local root = character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			local data = if ProfileController ~= nil then ProfileController:Get() else nil
			local legs = if data ~= nil then (data.Stats.Legs or 0) else 0
			return Formulas.FlightBlend(root.AssemblyLinearVelocity.Magnitude, Formulas.FlightSpeed(legs))
		end
	end

	-- Remote fliers: the band is the pose. Mapped onto the same 0-1 the local player
	-- uses so both go through one blend, rather than one path lerping and the other
	-- switching between three fixed poses.
	if state == "Cruise" then
		return 1
	elseif state == "Glide" then
		return Formulas.FLIGHT_CRUISE_FRACTION * 0.6
	end
	return 0
end

--[[
	The two silhouettes a blend sits between, and how far between them it is.

	Hover to Glide occupies the lower part of the range and Glide to Cruise the upper,
	split at the same fraction FlightBand uses — so the pose crosses into the cruise
	shape at exactly the speed the band says it should, and the local smooth path and
	the remote coarse path agree about where the boundary is.
]]
local function silhouettesAt(blend: number): (FlightConfig.FlightPose, FlightConfig.FlightPose, number)
	local hover = FlightConfig.Get("Hover") :: FlightConfig.FlightPose
	local glide = FlightConfig.Get("Glide") :: FlightConfig.FlightPose
	local cruise = FlightConfig.Get("Cruise") :: FlightConfig.FlightPose

	local split = Formulas.FLIGHT_CRUISE_FRACTION
	if blend <= split then
		return hover, glide, if split > 1e-4 then blend / split else 0
	end
	local span = math.max(1e-4, 1 - split)
	return glide, cruise, math.clamp((blend - split) / span, 0, 1)
end

function FlightPoseController:_apply(delta: number)
	local now = os.clock()

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local target = targetBlendFor(character)
		if target == nil then
			-- Landed. Fade out rather than dropping the pose on the frame the attribute
			-- cleared: a body that snaps from a cruise to standing looks like it was
			-- teleported, and the humanoid's own walk cycle is arriving at the same time.
			entry.releasing = true
		else
			entry.releasing = false
			entry.blend += (target - entry.blend) * math.min(1, FlightConfig.POSE_RESPONSIVENESS * delta)
		end

		if entry.releasing then
			entry.weight -= delta / FlightConfig.BLEND_OUT_SECONDS
			if entry.weight <= 0 then
				self:_clear(character)
				continue
			end
		else
			entry.weight = math.min(1, (now - entry.startedAt) / FlightConfig.BLEND_IN_SECONDS)
		end

		local from, to, alpha = silhouettesAt(entry.blend)
		local motions = FlightConfig.Blend(from, to, alpha)

		-- The idle sway. A hovering body with perfectly still joints is a mannequin;
		-- a cruising one barely breathes, because at speed the read is a rigid arrow.
		local swayScale = 1 - (1 - FlightConfig.CRUISE_SWAY_SCALE) * entry.blend
		local sway = math.sin(now * (math.pi * 2 / FlightConfig.SWAY_SECONDS))
			* FlightConfig.SWAY_DEGREES
			* swayScale

		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end
			for _, motion in motions do
				if motion.Joint ~= bound.name then
					continue
				end
				local posed = PosePlayback.PoseAt(motion, 0)
				if bound.name == "LeftShoulder" or bound.name == "LeftKnee" then
					posed *= CFrame.Angles(math.rad(sway), 0, 0)
				elseif bound.name == "RightKnee" then
					posed *= CFrame.Angles(math.rad(-sway), 0, 0)
				end
				-- Lerped from identity by the fade weight. This is the same blend-in
				-- TrainingPoseController uses, and it is what stops takeoff popping.
				bound.joint.Transform = IDENTITY:Lerp(posed, entry.weight)
				break
			end
		end
	end
end

--[[
	Starts or stops posing a character as its flight state changes.
]]
function FlightPoseController:_sync(character: Model)
	local state = character:GetAttribute(FlightConfig.STATE_ATTRIBUTE)

	if type(state) ~= "string" then
		-- Landing is handled by _apply's fade, not by clearing here, so the pose has
		-- somewhere to fade from. A character with no entry at all has nothing to do.
		return
	end

	local entry = active[character]
	if entry ~= nil then
		if entry.releasing then
			-- Taking off again inside the landing fade. The pose is part-way out, so it
			-- has to fade back in from wherever it actually is rather than from a fresh
			-- clock — restarting the timer here would snap a half-faded body to full.
			entry.startedAt = os.clock() - entry.weight * FlightConfig.BLEND_IN_SECONDS
		end
		entry.releasing = false
		return
	end

	local joints = bindJoints(character)
	if #joints == 0 then
		return
	end

	active[character] = {
		joints = joints,
		blend = 0,
		weight = 0,
		releasing = false,
		startedAt = os.clock(),
	}
end

function FlightPoseController:_watch(character: Model)
	character:GetAttributeChangedSignal(FlightConfig.STATE_ATTRIBUTE):Connect(function()
		self:_sync(character)
	end)
	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			self:_clear(character)
		end
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		-- Dying mid-flight has to drop the pose immediately rather than fading it. A
		-- corpse easing gracefully out of a superhero cruise is worse than a hard cut.
		humanoid.Died:Connect(function()
			self:_clear(character)
		end)
	end

	self:_sync(character)
end

function FlightPoseController:_track(player: Player)
	if player.Character ~= nil then
		self:_watch(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		self:_watch(character)
	end)
	player.CharacterRemoving:Connect(function(character: Model)
		self:_clear(character)
	end)
end

function FlightPoseController:Init()
	FlightController = Loader.Get("FlightController")
	ProfileController = Loader.Get("ProfileController")
end

function FlightPoseController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	RunService.PreSimulation:Connect(function(delta: number)
		self:_apply(delta)
	end)
end

return FlightPoseController
