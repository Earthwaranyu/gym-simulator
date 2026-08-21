--!strict
--[[
	GaitController — walks and runs every body you can see.

	The fourth and last of the pose controllers, after TrainingPoseController,
	StrikeController and FlightPoseController, and built the same way: resolve the
	joints once, write Transform on PreSimulation, clear back to identity when done.

	Unlike all three of those, this one needs nothing replicated. Flight had to invent an
	attribute because it is client-authoritative and invisible — nothing on the wire said
	who was airborne. Ground movement is different: AssemblyLinearVelocity and
	Humanoid.WalkSpeed both replicate for free, so every client can already see exactly
	how fast every other character is going. No remote, no attribute, nothing to keep in
	sync, and a remote player's gait is derived from the same numbers as their own.

	PreSimulation for the reason TrainingPoseController's header gives: it is the window
	after the animator has evaluated and before the world step reads the joint
	transforms. Roblox's own walk and run clips are still playing underneath — nothing
	disables the default Animate script, and disabling it would take jump, fall, climb
	and swim with it — so this overrides the stock animation on the joints GaitConfig
	names and leaves everything else to the engine.

	Priority 7, which is deliberately the highest of the four and therefore the *weakest*.
	The Loader sorts descending and first-connected runs first, so the last writer wins;
	writing first means training poses (5), strikes and flight (6) all overwrite this.
	A punch thrown while running should look like a punch. The explicit guards in
	_shouldApply do the same job directly, and the ordering is the belt to their braces.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)
local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local GaitConfig = require(ReplicatedStorage.Modules.GaitConfig)
local FlightConfig = require(ReplicatedStorage.Modules.FlightConfig)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)

local GaitController = {
	Name = "GaitController",
	Priority = 7,
}

local IDENTITY: CFrame = CFrame.identity

-- Past this the gait is not worth computing. A character across the map is a few pixels
-- tall and this runs per visible character per frame, which is a far bigger budget than
-- flight ever was — only a handful of people are ever airborne, but everybody walks.
local CULL_DISTANCE = 260

local VfxController: any = nil

type Bound = { name: string, joint: any }

type Entry = {
	joints: { Bound },
	-- Where in the stride we are, 0 to 1. Owned here rather than derived from a clock:
	-- see _apply for why that is the whole trick.
	phase: number,
	-- Walk at 0, sprint at 1. Eased toward the speed-derived target.
	blend: number,
	-- Fade against whatever the animator is doing, 0 to 1.
	weight: number,
	releasing: boolean,
	-- Which footfall we last fired, so a stride cannot double-fire its dust.
	lastFootfall: number,
}

local active: { [Model]: Entry } = {}
-- Mob models to consider each frame, kept as a set rather than re-read from the tag
-- every frame. A field of six goblins and a boss are all walking at once.
local mobs: { [Model]: boolean } = {}

local function bindJoints(character: Model): { Bound }
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return {}
	end

	local bound: { Bound } = {}
	for _, name in GaitConfig.Joints do
		local joint = PosePlayback.FindJoint(character, humanoid.RigType, name)
		if joint ~= nil then
			table.insert(bound, { name = name, joint = joint })
		end
	end
	return bound
end

function GaitController:_clear(character: Model)
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
	Whether this character should be walking right now, and how fast.

	Returns nil for every state that owns the body more strongly than a gait does. These
	are checked explicitly rather than left to write order, because "the training pose
	happens to run later" is a fact about Loader priorities that nothing in this file
	states, and a reordering would silently make a mounted player jog on the spot.
]]
local function groundSpeedFor(character: Model): number?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil or not root:IsA("BasePart") or humanoid.Health <= 0 then
		return nil
	end

	-- Bolted to a machine, mid-punch, or in the air: all three own the body already.
	if character:GetAttribute(PoseConfig.POSE_ATTRIBUTE) ~= nil then
		return nil
	end
	if character:GetAttribute(FlightConfig.STATE_ATTRIBUTE) ~= nil then
		return nil
	end
	local strikeAt = character:GetAttribute(StrikeConfig.STRIKE_ATTRIBUTE)
	if type(strikeAt) == "number" then
		local strikeId = character:GetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE)
		local strike = if type(strikeId) == "string" then StrikeConfig.Get(strikeId) else nil
		if strike ~= nil and workspace:GetServerTimeNow() - strikeAt < strike.Duration then
			return nil
		end
	end

	-- Only running counts. Jumping, falling, swimming and climbing keep the engine's
	-- own clips, which is correct — this replaces locomotion, not every state a
	-- humanoid has.
	local state = humanoid:GetState()
	if state ~= Enum.HumanoidStateType.Running and state ~= Enum.HumanoidStateType.RunningNoPhysics then
		return nil
	end
	if humanoid.Sit then
		return nil
	end

	-- Horizontal only. A character riding a lift is not walking.
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	if speed < Formulas.MIN_GAIT_SPEED then
		return nil
	end
	return speed
end

--[[
	The speed range the gait is measured against — absolute, not per character.

	This used to read the character's own WalkSpeed as the top of the range, which is
	wrong the moment there are three silhouettes: relative to themselves, every player is
	at 100% as soon as they hold Shift, so a fresh player jogging at 24 studs a second
	got exactly the same flat-out ninja run as somebody with forty Legs doing 64.

	Measured against the global ceiling instead, speed means the same thing for everybody
	and the dash becomes something Legs earns. A fresh sprint sits a little past the
	walk-to-sprint split and reads as a shonen run; only genuine top speed reaches the
	ninja one.
]]
local function speedRange(): (number, number)
	return Formulas.WalkSpeed(0), Formulas.SPRINT_CEILING
end

function GaitController:_apply(delta: number)
	local camera = workspace.CurrentCamera
	local eye = if camera ~= nil then camera.CFrame.Position else Vector3.zero

	for character, entry in active do
		if character.Parent == nil then
			self:_clear(character)
			continue
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root == nil or not root:IsA("BasePart") then
			self:_clear(character)
			continue
		end
		if (root.Position - eye).Magnitude > CULL_DISTANCE then
			-- Out of sight. Hand the joints back rather than freezing them, so a
			-- character that streams back in is not holding a stale mid-stride pose.
			self:_clear(character)
			continue
		end

		local speed = groundSpeedFor(character)
		if speed == nil then
			entry.releasing = true
			entry.weight -= delta / GaitConfig.BLEND_OUT_SECONDS
			if entry.weight <= 0 then
				self:_clear(character)
				continue
			end
		else
			entry.releasing = false
			entry.weight = math.min(1, entry.weight + delta / GaitConfig.BLEND_IN_SECONDS)

			local walkSpeed, topSpeed = speedRange()
			-- Capped, so the pose never escalates past what a player with no Legs
			-- already sees when they hold shift. Applied here rather than inside
			-- Formulas.GaitBlend on purpose: VfxController computes its own blend
			-- from that same function for speed lines and the sprint burst, and
			-- those are a fine "you are fast" cue that has nothing to do with the
			-- walk cycle. Capping the shared formula would silently take them too.
			local target = math.min(Formulas.GaitBlend(speed, walkSpeed, topSpeed), GaitConfig.MAX_POSE_BLEND)
			entry.blend += (target - entry.blend) * math.min(1, GaitConfig.BLEND_RESPONSIVENESS * delta)

			-- The trick, and the one place this cannot copy TrainingPoseController.
			--
			-- That controller stores a startedAt and lets AlphaAt divide wall clock by a
			-- rep interval, resetting startedAt whenever the interval changes. Correct
			-- for a machine that changes pace a few times a set; catastrophic here,
			-- because the interval changes every frame as speed varies — resetting on
			-- change would restart the cycle sixty times a second and the legs would
			-- stand still while the body slid along.
			--
			-- So the phase is accumulated, and accumulated from distance covered rather
			-- than from time. A character slowing down then takes shorter steps instead
			-- of keeping a cadence while decelerating out from under their own feet,
			-- which is the classic way a speed-driven gait ends up moon-walking.
			local stride = Formulas.StrideInterval(speed)
			local previousPhase = entry.phase
			entry.phase = (entry.phase + delta / stride) % 1
			self:_fireFootfalls(character, root, previousPhase, entry)
		end

		local weight = math.clamp(entry.weight, 0, 1)
		local blend = entry.blend
		-- Alpha is per joint, because each one carries its own Phase offset — that
		-- single field is the whole of limb opposition.
		-- Only the MotionStyle and Cycles are read off this, and all three gaits share
		-- both, so which one is handed in does not matter — the walk is simply the one
		-- that always exists.
		local shaped = GaitConfig.Walk
		local elapsed = entry.phase * 1
		for _, bound in entry.joints do
			if bound.joint.Parent == nil then
				continue
			end
			local motion = GaitConfig.BlendJoint(bound.name, blend)
			if motion == nil then
				continue
			end
			-- Interval of 1 with elapsed as the raw phase: AlphaAt divides the two, so
			-- passing the accumulated phase directly is what lets this drive the cycle
			-- without ever restarting it.
			local alpha = PosePlayback.AlphaAt(shaped, motion, elapsed, 1)
			local posed = PosePlayback.PoseAt(motion, alpha)

			if bound.name == "Root" then
				posed = self:_rootExtras(posed, entry, blend)
			elseif bound.name == "Neck" then
				-- Head pitch cancels the lean, so the character always looks where they
				-- are going rather than at the floor. Derived from the same number the
				-- root leans by rather than hand-written into each pose, which is how the
				-- sprint previously ended up with its head tipped further down than its
				-- body. The poses carry only the Y counter-rotation that keeps the head
				-- steady while the shoulders roll.
				posed *= CFrame.Angles(-math.rad(Formulas.RunLean(blend)), 0, 0)
			end

			bound.joint.Transform = IDENTITY:Lerp(posed, weight)
		end
	end
end

--[[
	The lean and the bob, both of which belong on the root and neither of which can be a
	JointMotion.

	The lean grows smoothly with speed, so it cannot live in either pose — it would
	switch on when the sprint silhouette took over instead of arriving with the speed.
	The bob runs at twice the stride frequency, because a body rises and falls once per
	*step* and a cycle is two steps, and a Pose drives every one of its joints at the
	same rate.

	RunLean already carries its own sign: negative pitches the torso forward on the Root
	joint, matching FlightConfig's glide and cruise. Nothing is negated here, and nothing
	should be — the first build leaned the wrong way precisely because the sign was
	something a call site had to remember.
]]
function GaitController:_rootExtras(posed: CFrame, entry: Entry, blend: number): CFrame
	local lean = math.rad(Formulas.RunLean(blend))
	local bob = -math.abs(math.cos(entry.phase * math.pi * 2)) * Formulas.GaitBob(blend)
	return CFrame.new(0, bob, 0) * posed * CFrame.Angles(lean, 0, 0)
end

--[[
	Fires the dust on the frame a foot actually lands.

	Only possible because the cycle is ours: with a stock clip the best available option
	is a timer that drifts against the animation, whereas a footfall here is a known
	point in the phase. Crossing detection rather than a proximity test, so a very fast
	stride cannot skip a footfall and a very slow one cannot fire it twice.
]]
function GaitController:_fireFootfalls(character: Model, root: BasePart, previous: number, entry: Entry)
	if VfxController == nil or entry.weight < 0.5 then
		return
	end

	for index, footfall in GaitConfig.FOOTFALL_PHASES do
		local crossed = if previous <= entry.phase
			then previous < footfall.Phase and entry.phase >= footfall.Phase
			-- Wrapped past 1 this frame, so the window is the two ends joined.
			else previous < footfall.Phase or entry.phase >= footfall.Phase
		if crossed and entry.lastFootfall ~= index then
			entry.lastFootfall = index
			VfxController:PlayFootfall(character, root, entry.blend)
		end
	end
end

function GaitController:_sync(character: Model)
	if active[character] ~= nil then
		return
	end
	if groundSpeedFor(character) == nil then
		return
	end

	local joints = bindJoints(character)
	if #joints == 0 then
		return
	end

	active[character] = {
		joints = joints,
		phase = 0,
		blend = 0,
		weight = 0,
		releasing = false,
		lastFootfall = 0,
	}
end

function GaitController:_watch(character: Model)
	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			self:_clear(character)
		end
	end)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil then
		-- A corpse must not keep striding. Hard cut rather than a fade, for the same
		-- reason the flight pose hard-cuts on death.
		humanoid.Died:Connect(function()
			self:_clear(character)
		end)
	end
end

function GaitController:_track(player: Player)
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

function GaitController:Init()
	VfxController = Loader.Get("VfxController")
end

function GaitController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	-- Monsters walk too, and everything above already works on any model: the entries
	-- are keyed by Model, groundSpeedFor asks a Humanoid and a root part rather than a
	-- Player, and a rig without the joints a gait names binds nothing and is skipped.
	-- FlinchController takes mobs the same way and for the same reason.
	--
	-- Their speeds land where you would want: a goblin at 20 sits just past a walk and
	-- a boss at 32 is a third of the way to the dash silhouette, so goblins jog in and
	-- a boss charges, off the same two poses the player uses.
	local function watchMob(instance: Instance)
		if instance:IsA("Model") then
			mobs[instance] = true
		end
	end
	for _, model in CollectionService:GetTagged(MobConfig.MOB_TAG) do
		watchMob(model)
	end
	CollectionService:GetInstanceAddedSignal(MobConfig.MOB_TAG):Connect(watchMob)
	CollectionService:GetInstanceRemovedSignal(MobConfig.MOB_TAG):Connect(function(instance: Instance)
		if instance:IsA("Model") then
			mobs[instance] = nil
			self:_clear(instance)
		end
	end)

	RunService.PreSimulation:Connect(function(delta: number)
		-- Characters are picked up here rather than from an attribute change, because
		-- there is no attribute: starting to walk is not an event anybody publishes, it
		-- is just a velocity going up. Cheap enough — it is a table lookup per player
		-- until one of them actually moves.
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character ~= nil and active[character] == nil then
				self:_sync(character)
			end
		end
		for model in mobs do
			if model.Parent == nil then
				mobs[model] = nil
			elseif active[model] == nil then
				self:_sync(model)
			end
		end

		self:_apply(delta)
	end)
end

return GaitController
