--!strict
--[[
	VfxController — builds and plays the world effects in VfxConfig.

	The sibling of StrikeController, built the same way and for the same reason. The
	server stamps one attribute on a character; every client notices and produces the
	effect locally. Nothing about a shockwave is replicated, because it does not need
	to be: the timings live in StrikeConfig, the shapes live in VfxConfig, and every
	machine already has both. All that crosses the wire is "he slammed, at this moment,
	with this radius".

	That is also what makes the effects free to be expensive. A crater built here costs
	one client one frame of part creation; a crater built on the server would cost every
	client the replication of fourteen parts, and would still be there in the workspace
	for anyone who joined afterwards.

	Everything is parented under CurrentCamera, which is the standard place for local
	scenery: children of the camera are never replicated, never collide, and are cleared
	automatically when the camera is rebuilt on respawn — so an effect interrupted by a
	death cannot leak.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local StrikeConfig = require(ReplicatedStorage.Modules.StrikeConfig)
local VfxConfig = require(ReplicatedStorage.Modules.VfxConfig)

local VfxController = {
	Name = "VfxController",
	Priority = 6,
}

local EffectsController: any = nil

-- Set by GroundSlam, read here. Declared as a plain string in both places rather than
-- shared through a module because it is one attribute name and a config module holding
-- a single constant is a worse seam than two matching strings with a comment.
local SLAM_RADIUS_ATTRIBUTE = "SlamRadius"
local BLOCKING_ATTRIBUTE = "Blocking"

-- Rough drop from a HumanoidRootPart to the floor. The same constant GroundSlam uses
-- server-side to pick its epicentre, so the crater appears where the damage happened.
local ROOT_TO_FLOOR = 3

-- Past this many simultaneous effects, new ones are dropped. A six-player brawl can
-- ask for a slam, two heavies and three guards inside a second, and the frame that
-- builds all of them is the frame the player is trying to fight in.
local MAX_CONCURRENT = 12
local activeCount = 0

local container: Folder? = nil

local function color(rgb: { number }): Color3
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function easingStyle(easing: VfxConfig.Easing): Enum.EasingStyle
	if easing == "Out" then
		return Enum.EasingStyle.Quart
	elseif easing == "In" then
		return Enum.EasingStyle.Quad
	elseif easing == "Snap" then
		return Enum.EasingStyle.Exponential
	end
	return Enum.EasingStyle.Linear
end

--[[
	The folder every effect part lives in, created on demand.

	Re-created rather than cached across respawns: CurrentCamera is replaced when the
	character does, which silently orphans a cached folder and makes every effect after
	the first death invisible.
]]
local function ensureContainer(): Folder
	local camera = workspace.CurrentCamera
	local existing = container
	if existing ~= nil and existing.Parent == camera then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "Vfx"
	folder.Parent = camera
	container = folder
	return folder
end

--[[
	A part configured the way every effect part has to be: weightless, intangible, and
	invisible to raycasts. A single missed CanQuery here would put a shockwave ring in
	the path of the combat range checks, and the bug would look like combat randomly
	missing rather than like a rendering mistake.
]]
local function effectPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

--[[
	What the floor under a point is made of.

	Used so a slam breaks the actual gym: tile shatters as tile, grass as grass. The
	raycast ignores the character it came from — without that, the ray starting inside
	somebody's legs samples their skin colour and the crater comes out flesh-coloured.
]]
local function sampleFloor(position: Vector3, ignore: Model?): (Color3, Enum.Material)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ensureContainer(), ignore :: any }
	params.IgnoreWater = true

	local result = workspace:Raycast(position + Vector3.yAxis * 4, Vector3.yAxis * -12, params)
	if result == nil then
		return Color3.fromRGB(96, 92, 88), Enum.Material.Concrete
	end
	return result.Instance.Color, result.Instance.Material
end

-- === Elements ===============================================================

local function playRing(spec: VfxConfig.RingSpec, origin: CFrame, radius: number)
	local part = effectPart("Ring")
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.Neon
	part.Color = color(spec.Color)
	part.Transparency = spec.StartTransparency
	-- A Cylinder's height runs along its X axis, so a flat disc on the ground needs the
	-- part rotated ninety degrees about Z. This is the single most common way a ring
	-- effect comes out standing on its edge.
	local flat = origin * CFrame.Angles(0, 0, math.rad(90))
	part.CFrame = flat
	part.Size = Vector3.new(spec.Height, radius * spec.StartScale * 2, radius * spec.StartScale * 2)
	part.Parent = ensureContainer()

	local info = TweenInfo.new(spec.Seconds, easingStyle(spec.Easing), Enum.EasingDirection.Out)
	TweenService:Create(part, info, {
		Size = Vector3.new(spec.Height, radius * spec.EndScale * 2, radius * spec.EndScale * 2),
		Transparency = 1,
	}):Play()

	Debris:AddItem(part, spec.Seconds + 0.1)
end

local function playFlash(spec: VfxConfig.FlashSpec, origin: CFrame, radius: number)
	local part = effectPart("Flash")
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Color = color(spec.Color)
	part.Transparency = 0
	part.CFrame = origin
	part.Size = Vector3.one * radius * spec.StartScale
	part.Parent = ensureContainer()

	local info = TweenInfo.new(spec.Seconds, easingStyle(spec.Easing), Enum.EasingDirection.Out)
	TweenService:Create(part, info, {
		Size = Vector3.one * radius * spec.EndScale,
		Transparency = 1,
	}):Play()

	Debris:AddItem(part, spec.Seconds + 0.1)
end

--[[
	The floor coming apart: a ring of slabs hinged up out of the ground.

	Each slab tilts outward around its own inner edge rather than rotating about its
	centre, which is why the pivot is offset by half the slab before the rotation is
	applied. Rotating about the centre sinks the inner half through the floor and the
	fan reads as a spinning plate.
]]
local function playShards(spec: VfxConfig.ShardSpec, origin: CFrame, radius: number, ignore: Model?)
	local shardColor = color(spec.Color)
	local shardMaterial = Enum.Material.Slate
	if spec.SampleFloor then
		shardColor, shardMaterial = sampleFloor(origin.Position, ignore)
	end

	local parent = ensureContainer()
	local hold = spec.Seconds * spec.HoldFraction
	local rise = (spec.Seconds - hold) * 0.35
	local fall = spec.Seconds - hold - rise

	for index = 1, spec.Count do
		-- Jittered off the even division so the fan does not read as a clock face.
		local angle = (index / spec.Count) * math.pi * 2 + math.random() * 0.35
		local distance = radius * spec.Spread * (0.35 + math.random() * 0.65)
		local size = spec.MinSize:Lerp(spec.MaxSize, math.random())

		local part = effectPart("Shard")
		part.Size = size
		part.Color = shardColor
		part.Material = shardMaterial
		part.Transparency = 0

		local outward = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local resting =
			CFrame.lookAt(origin.Position + outward * distance, origin.Position + outward * (distance + 1))
		part.CFrame = resting * CFrame.new(0, -size.Y, 0)
		part.Parent = parent

		local tilt = math.rad(spec.TiltDegrees) * (0.6 + math.random() * 0.6)
		local peak = resting
			* CFrame.new(0, spec.RiseStuds * (0.5 + math.random() * 0.8), 0)
			-- Pivot on the inner edge: down half a slab, rotate, back up half a slab.
			* CFrame.new(0, -size.Y * 0.5, 0)
			* CFrame.Angles(tilt, 0, 0)
			* CFrame.new(0, size.Y * 0.5, 0)

		local up = TweenService:Create(
			part,
			TweenInfo.new(rise, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
			{ CFrame = peak }
		)
		up:Play()

		task.delay(rise + hold, function()
			if part.Parent == nil then
				return
			end
			-- Settling back into the floor rather than fading in place. A slab that
			-- fades while still standing up looks like it was deleted; one that sinks
			-- looks like the ground closed.
			TweenService:Create(
				part,
				TweenInfo.new(fall, Enum.EasingStyle.Sine, Enum.EasingDirection.In),
				{ CFrame = resting * CFrame.new(0, -size.Y * 1.2, 0), Transparency = 1 }
			):Play()
		end)

		Debris:AddItem(part, spec.Seconds + 0.2)
	end
end

local function playBurst(spec: VfxConfig.BurstSpec, origin: CFrame, _radius: number)
	local part = effectPart("Burst")
	part.Transparency = 1
	part.Size = Vector3.one * 0.2
	part.CFrame = origin
	part.Parent = ensureContainer()

	local emitter = Instance.new("ParticleEmitter")
	-- Set before anything else, because a ParticleEmitter with no texture emits
	-- particles that render as nothing — the effect fires, costs its frame, and is
	-- invisible, which is the hardest kind of VFX bug to spot.
	emitter.Texture = spec.Texture
	emitter.Color = ColorSequence.new(color(spec.Color))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.Size.Min),
		NumberSequenceKeypoint.new(1, spec.Size.Max),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.7, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Speed = spec.Speed
	emitter.Lifetime = spec.Lifetime
	emitter.SpreadAngle = Vector2.new(spec.Spread, spec.Spread)
	emitter.Acceleration = Vector3.new(0, -spec.Gravity, 0)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.LightEmission = 0.15
	-- Emit() once rather than Rate over time: a burst is an event, and a rate that has
	-- to be switched off is a rate that stays on when the effect is interrupted.
	emitter.Rate = 0
	emitter.Enabled = false
	emitter.Parent = part
	emitter:Emit(spec.Count)

	Debris:AddItem(part, spec.Seconds + spec.Lifetime.Max)
end

local function playScorch(spec: VfxConfig.ScorchSpec, origin: CFrame, radius: number)
	local part = effectPart("Scorch")
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.SmoothPlastic
	part.Color = color(spec.Color)
	part.Transparency = spec.StartTransparency
	-- Just clear of the floor. Flush with it and the two surfaces fight for the same
	-- pixels, which flickers as the camera moves.
	part.CFrame = origin * CFrame.new(0, 0.06, 0) * CFrame.Angles(0, 0, math.rad(90))
	part.Size = Vector3.new(0.08, radius * spec.Scale * 2, radius * spec.Scale * 2)
	part.Parent = ensureContainer()

	task.delay(spec.Seconds - spec.FadeSeconds, function()
		if part.Parent == nil then
			return
		end
		TweenService:Create(part, TweenInfo.new(spec.FadeSeconds), { Transparency = 1 }):Play()
	end)

	Debris:AddItem(part, spec.Seconds + 0.1)
end

--[[
	The guard dome, raised and dropped rather than played.

	Held separately from the one-shot effects because it is a state, not an event: it
	exists for exactly as long as the button is held. The first build routed it through
	Play() as an ordinary element, which gave it an element's lifetime — the barrier
	flashed for a third of a second and vanished while the guard was still up, and the
	only thing left saying you were blocking was a bar in the corner of the screen.

	Anchored and followed per frame rather than welded. A weld would make the dome part
	of the character's assembly, which changes its mass, its collisions and the physics
	ownership of somebody who is in the middle of being knocked back.
]]
local guardDomes: { [Model]: Part } = {}

local function dropGuard(character: Model)
	local dome: Part? = guardDomes[character]
	if dome == nil then
		return
	end
	guardDomes[character] = nil

	-- Shrunk away rather than faded. ForceField draws its own shell and ignores the
	-- part's Transparency entirely — a dome tweened to Transparency = 1 stays exactly
	-- as visible as it was, which is how the first build ended up with barriers that
	-- never came down. Size is the only handle the material leaves us.
	local spec = VfxConfig.Guard
	TweenService
		:Create(dome, TweenInfo.new(spec.DropSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Size = Vector3.one * 0.1,
		})
		:Play()
	Debris:AddItem(dome, spec.DropSeconds + 0.1)
end

local function raiseGuard(character: Model, attachTo: BasePart)
	if (guardDomes[character] :: Part?) ~= nil then
		return
	end

	local camera = workspace.CurrentCamera
	local spec = VfxConfig.Guard
	if camera ~= nil and (camera.CFrame.Position - attachTo.Position).Magnitude > spec.CullDistance then
		return
	end

	local dome = effectPart("GuardDome")
	dome.Shape = Enum.PartType.Ball
	dome.Material = Enum.Material.ForceField
	dome.Color = color(spec.Color)
	dome.Transparency = spec.Transparency
	dome.Size = Vector3.one * spec.Radius
	dome.CFrame = CFrame.new(attachTo.Position)
	dome.Parent = ensureContainer()
	guardDomes[character] = dome

	TweenService:Create(
		dome,
		TweenInfo.new(spec.RaiseSeconds, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = Vector3.one * spec.Radius * 2 }
	):Play()

	-- One connection per raise, cleaned up the moment the dome or the character is
	-- gone. Following in RenderStepped rather than on Heartbeat because the dome is
	-- drawn around a character the camera is usually looking straight at, and a frame
	-- of lag is visible as the barrier sliding off the body.
	local follow: RBXScriptConnection
	follow = RunService.RenderStepped:Connect(function()
		if dome.Parent == nil or attachTo.Parent == nil then
			follow:Disconnect()
			return
		end
		dome.CFrame = CFrame.new(attachTo.Position)

		-- The barrier itself warns that it is failing. A player in a fight is watching
		-- the fight, not the meter in the corner, and the break costs three seconds.
		local meter = character:GetAttribute("BlockMeter")
		local low = type(meter) == "number" and meter < 0.25
		dome.Color = color(if low then spec.WarnColor else spec.Color)
	end)
end

--[[
	The dome swelling as it eats a hit. Does nothing if there is no dome, which is the
	correct behaviour for an absorb that arrives a frame after the guard came down.
]]
local function pulseGuard(character: Model)
	local dome: Part? = guardDomes[character]
	if dome == nil then
		return
	end

	-- Size only, for the same reason dropGuard shrinks rather than fades: ForceField
	-- ignores Transparency, so a brightness pulse would be a property write that
	-- changed nothing on screen. The swell carries the whole read.
	local spec = VfxConfig.Guard
	local resting = Vector3.one * spec.Radius * 2
	local out = TweenService:Create(
		dome,
		TweenInfo.new(spec.PulseSeconds * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = resting * (1 + spec.PulseScale) }
	)
	out.Completed:Connect(function()
		if dome.Parent == nil then
			return
		end
		TweenService:Create(
			dome,
			TweenInfo.new(spec.PulseSeconds * 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Size = resting }
		):Play()
	end)
	out:Play()
end

local function playTrail(spec: VfxConfig.TrailSpec, attachTo: BasePart?)
	if attachTo == nil then
		return
	end

	local top = Instance.new("Attachment")
	top.Name = "VfxTrailTop"
	top.Position = Vector3.new(0, spec.Width * 0.5, 0)
	top.Parent = attachTo

	local bottom = Instance.new("Attachment")
	bottom.Name = "VfxTrailBottom"
	bottom.Position = Vector3.new(0, -spec.Width * 0.5, 0)
	bottom.Parent = attachTo

	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.Color = ColorSequence.new(color(spec.Color))
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = spec.Lifetime
	trail.LightEmission = 0.4
	trail.FaceCamera = true
	trail.Parent = attachTo

	task.delay(spec.Seconds, function()
		trail.Enabled = false
	end)
	Debris:AddItem(trail, spec.Seconds + spec.Lifetime)
	Debris:AddItem(top, spec.Seconds + spec.Lifetime)
	Debris:AddItem(bottom, spec.Seconds + spec.Lifetime)
end

-- === Camera ================================================================
--
-- Shake and the impact beat both write to the camera, so they share one render-step
-- hook. Two independent hooks would each read a CFrame the other had already modified
-- and the offsets would compound into a camera that drifts away and never comes back.

type ShakeState = {
	Until: number,
	Seconds: number,
	Amplitude: number,
	Roughness: number,
}

local shake: ShakeState? = nil
local holdUntil = 0
local holdCFrame: CFrame? = nil
local baseFieldOfView: number? = nil

local function updateCamera()
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end

	local now = os.clock()

	-- The impact beat, first: the camera stops where it was and the field of view snaps
	-- in. Applied before shake so the shake still reads on top of a held frame.
	if now < holdUntil then
		local held = holdCFrame
		if held ~= nil then
			camera.CFrame = held
		end
	elseif baseFieldOfView ~= nil then
		camera.FieldOfView = baseFieldOfView
		baseFieldOfView = nil
		holdCFrame = nil
	end

	local state = shake
	if state == nil then
		return
	end
	if now >= state.Until then
		shake = nil
		return
	end

	-- Fades out over its own lifetime, so a shake never ends on a hard cut back to a
	-- steady camera — which is more noticeable than the shake itself.
	local remaining = (state.Until - now) / state.Seconds
	local magnitude = state.Amplitude * remaining * remaining
	local t = now * state.Roughness
	local offset = Vector3.new(math.sin(t * 1.7), math.sin(t * 2.3), math.sin(t * 1.1)) * magnitude
	camera.CFrame = camera.CFrame * CFrame.new(offset)
end

local function startShake(spec: VfxConfig.ShakeSpec, position: Vector3)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	if distance >= spec.FalloffRadius then
		return
	end

	-- Linear falloff. A slam across the room should be felt faintly, and an
	-- inverse-square falloff makes "faintly" indistinguishable from "not at all".
	local strength = 1 - distance / spec.FalloffRadius
	local amplitude = spec.Amplitude * strength

	local existing = shake
	-- Two shakes at once take the louder one rather than adding. Adding makes a
	-- multi-hit exchange progressively unplayable.
	if existing ~= nil and existing.Amplitude > amplitude and os.clock() < existing.Until then
		return
	end
	shake = {
		Until = os.clock() + spec.Seconds,
		Seconds = spec.Seconds,
		Amplitude = amplitude,
		Roughness = spec.Roughness,
	}
end

local function startHold(spec: VfxConfig.HitStopSpec)
	local camera = workspace.CurrentCamera
	if camera == nil then
		return
	end
	holdCFrame = camera.CFrame
	holdUntil = os.clock() + spec.Seconds
	if baseFieldOfView == nil then
		baseFieldOfView = camera.FieldOfView
	end
	-- The punch inward. TimeScale is how hard the beat lands, so a full stop (0) is
	-- also the deepest zoom.
	camera.FieldOfView = (baseFieldOfView :: number) * (1 - (1 - spec.TimeScale) * 0.06)
end

-- === Playback ===============================================================

--[[
	Fires a named effect.

	`origin` is where it happens, `attachTo` is the part a dome or a trail rides on, and
	`radius` overrides the effect's own — Ground Slam resolves its radius from Legs, so
	the crater is exactly as wide as the blast that made it.
]]
function VfxController:Play(
	effectId: string,
	origin: CFrame,
	attachTo: BasePart?,
	radius: number?,
	ignore: Model?
)
	local effect = VfxConfig.Get(effectId)
	if effect == nil then
		return
	end

	local camera = workspace.CurrentCamera
	if camera ~= nil and (camera.CFrame.Position - origin.Position).Magnitude > effect.CullDistance then
		return
	end
	if activeCount >= MAX_CONCURRENT then
		return
	end

	activeCount += 1
	task.delay(VfxConfig.BusyDuration(effect), function()
		activeCount -= 1
	end)

	local size = radius or effect.Radius
	for _, element in effect.Elements do
		local function run()
			if element.Kind == "Ring" then
				playRing(element, origin, size)
			elseif element.Kind == "Flash" then
				playFlash(element, origin, size)
			elseif element.Kind == "Shards" then
				playShards(element, origin, size, ignore)
			elseif element.Kind == "Burst" then
				playBurst(element, origin, size)
			elseif element.Kind == "Scorch" then
				playScorch(element, origin, size)
			elseif element.Kind == "Trail" then
				playTrail(element, attachTo)
			elseif element.Kind == "Shake" then
				startShake(element, origin.Position)
			elseif element.Kind == "HitStop" then
				startHold(element)
			end
		end

		if element.Delay <= 0 then
			run()
		else
			task.delay(element.Delay, run)
		end
	end
end

-- === Wiring =================================================================

local function rootOf(character: Model): BasePart?
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

--[[
	The part an effect anchored to "RightHand" rides on.

	R15 first, then the R6 name, then the root. The fallback chain matters because a
	character can be mid-rig-swap when a strike lands, and a nil here would silently
	drop the trail rather than putting it somewhere approximately right.
]]
local function handOf(character: Model): BasePart?
	for _, name in { "RightHand", "Right Arm", "RightLowerArm" } do
		local part = character:FindFirstChild(name)
		if part ~= nil and part:IsA("BasePart") then
			return part
		end
	end
	return rootOf(character)
end

--[[
	Plays one strike's scheduled effects.

	The schedule is read off the strike itself, so an effect's timing is the animation's
	timing: retiming a clip in StrikeConfig moves its crater with it and there is no
	second table to keep in sync.
]]
function VfxController:_playStrike(character: Model, strikeId: string)
	local strike = StrikeConfig.Get(strikeId)
	if strike == nil or strike.Vfx == nil then
		return
	end

	for _, scheduled in strike.Vfx do
		task.delay(strike.Duration * scheduled.At, function()
			local root = rootOf(character)
			if root == nil or root.Parent == nil then
				return
			end

			local attach = scheduled.Attach
			if attach == "Ground" then
				local radius = character:GetAttribute(SLAM_RADIUS_ATTRIBUTE)
				self:Play(
					scheduled.Effect,
					CFrame.new(root.Position - Vector3.yAxis * ROOT_TO_FLOOR),
					root,
					if type(radius) == "number" then radius else nil,
					character
				)
			elseif attach == "RightHand" then
				local hand = handOf(character) or root
				self:Play(scheduled.Effect, CFrame.new(hand.Position), hand, nil, character)
			else
				self:Play(scheduled.Effect, root.CFrame, root, nil, character)
			end
		end)
	end
end

function VfxController:_watch(character: Model)
	character:GetAttributeChangedSignal(StrikeConfig.STRIKE_ATTRIBUTE):Connect(function()
		local at = character:GetAttribute(StrikeConfig.STRIKE_ATTRIBUTE)
		if type(at) ~= "number" then
			return
		end
		local id = character:GetAttribute(StrikeConfig.STRIKE_ID_ATTRIBUTE)
		self:_playStrike(character, if type(id) == "string" then id else "Punch")
	end)

	-- The guard is watched on every character, not only the local one: seeing that the
	-- person you are about to commit a Hard Punch into has a barrier up is the entire
	-- read the ability was built around.
	character:GetAttributeChangedSignal(BLOCKING_ATTRIBUTE):Connect(function()
		local root = rootOf(character)
		if root == nil then
			return
		end

		if character:GetAttribute(BLOCKING_ATTRIBUTE) == true then
			raiseGuard(character, root)
			-- The ring flash is a one-shot and stays an effect; only the barrier is a
			-- state. Both fire from the same attribute so they cannot disagree.
			self:Play("BlockRaise", root.CFrame, root, nil, character)
			if EffectsController ~= nil then
				EffectsController:Play("BlockRaise")
			end
		else
			dropGuard(character)
		end
	end)

	-- A character that dies or streams out mid-guard never gets the attribute change
	-- that would take its dome down, so the dome would outlive the body wearing it.
	character.AncestryChanged:Connect(function()
		if character.Parent == nil then
			dropGuard(character)
		end
	end)
end

function VfxController:_track(player: Player)
	if player.Character ~= nil then
		self:_watch(player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		self:_watch(character)
	end)
end

function VfxController:Init()
	EffectsController = Loader.Get("EffectsController")
end

function VfxController:Start()
	for _, player in Players:GetPlayers() do
		self:_track(player)
	end
	Players.PlayerAdded:Connect(function(player: Player)
		self:_track(player)
	end)

	-- The local player's own guard gets the absorb and break effects. They are sent as
	-- a remote rather than read from an attribute because "a hit was stopped" is an
	-- event, and an attribute can only say what is true now — two hits absorbed in the
	-- same frame would be one attribute change and one flash.
	Net.Event("BlockState").OnClientEvent:Connect(function(payload: any)
		local character = Players.LocalPlayer.Character
		local root = if character ~= nil then rootOf(character) else nil
		if root == nil or character == nil then
			return
		end

		if payload.Kind == "Absorb" then
			pulseGuard(character)
			self:Play("BlockAbsorb", root.CFrame, root, nil, character)
			if EffectsController ~= nil then
				EffectsController:Play("BlockAbsorb")
			end
		elseif payload.Kind == "Break" then
			-- Dropped here as well as on the attribute. The break and the attribute
			-- change arrive in the same server frame but over different channels, and
			-- a dome that lingered for even a few frames past the shatter would read
			-- as the guard having survived the hit that ended it.
			dropGuard(character)
			self:Play("BlockBreak", root.CFrame, root, nil, character)
			if EffectsController ~= nil then
				EffectsController:Play("BlockBreak")
			end
		end
	end)

	-- One hook for both camera effects, bound after the camera scripts so the offsets
	-- are applied to the CFrame the player actually sees rather than to one the default
	-- camera is about to overwrite.
	RunService:BindToRenderStep("VfxCamera", Enum.RenderPriority.Camera.Value + 1, updateCamera)
end

return VfxController
