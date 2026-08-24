--!strict
--[[
	EffectsController — sound and screen feedback.

	Everything is driven off events the game already fires, so no system had to be
	modified to make noise.

	Playback lives here; what a sound *is* lives in EffectsConfig. This file knows how to
	pick a variant, stack layers, route to a mix bus and emit from a part in the world —
	it does not know that a slam is louder than a jab. That split is what lets the whole
	game be re-mixed without touching a controller.

	The authoritative TrainingGain event lands on the completed-rep beat. It drives
	both the popup and rep sound, so neither can drift away from the procedural pose.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local EffectsConfig = require(ReplicatedStorage.Modules.EffectsConfig)
local SoundBus = require(ReplicatedStorage.Modules.SoundBus)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Icons = require(ReplicatedStorage.Modules.Icons)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Types = require(ReplicatedStorage.Modules.Types)

local EffectsController = {
	Name = "EffectsController",
	Priority = 5,
}

local ProfileController: any = nil
local CombatController: any = nil
local ToastController: any = nil

local lastRankId: string? = nil
local damageLayer: Frame? = nil
local hurtVignette: Frame? = nil
-- Training payouts rise as a short stream rather than one card replacing the last.
--
-- Destroying the previous card on every tick meant a fast machine showed a number that
-- never finished its own animation: the rep landed, the card appeared, and the next rep
-- deleted it mid-fade. Nothing accumulated on screen, which is exactly the sense of
-- momentum the number exists to give. Each card now lives out its GAIN_LIFETIME and the
-- older ones are already well up and half-faded by the time a new one starts, so they
-- read as a rising column rather than as the overlapping pile the old comment warned
-- about. The cap is what keeps that true — past four the column is a wall.
local GAIN_STACK_LIMIT = 4
local activeTrainingGains: { BillboardGui } = {}

-- How long one card lives, and how that time is spent. Long enough to read at a
-- glance, and the hold is what makes the fade feel deliberate rather than immediate:
-- the number is fully opaque while you look at it, then goes.
local GAIN_LIFETIME = 1.15
local GAIN_FADE_IN = 0.12
local GAIN_HOLD = 0.5

-- How long the hurt vignette takes to fade. Short: it is a warning, and one that
-- outstayed its welcome would be a permanent red frame in any real fight.
local HURT_FLASH_SECONDS = 0.34

-- Last play time per effect, per emitter, for the specs that declare a Cooldown.
-- Footfalls and sprint bursts fire off continuous state rather than discrete events, so
-- without this a single frame of jitter at the threshold retriggers them.
--
-- Keyed by the emitter Instance itself. The inner tables are weak-keyed so a character
-- that despawns is collected instead of being held for the session, and an Instance key
-- avoids building a string on every footstep — the highest-frequency sound in the game.
local lastPlayed: { [string]: { [Instance]: number } } = {}
-- The 2D case still needs a slot; SoundService stands in as "no emitter".
local NO_EMITTER: Instance = SoundService

--[[
	Resolves the one id this play will use. `Variants` is picked uniformly at random so a
	long set of reps does not turn into a metronome; `SoundId` is the single-file case.
]]
local function pickId(spec: EffectsConfig.SoundSpec): string?
	local variants = spec.Variants
	if variants ~= nil and #variants > 0 then
		return variants[math.random(#variants)]
	end
	if spec.SoundId ~= nil and spec.SoundId ~= "" then
		return spec.SoundId
	end
	return nil
end

--[[
	Builds and plays one spec. Layers recurse through here, which is why the emitter and
	the bus are passed down: a sub layer has to come from the same place in the world as
	the transient it is underneath, or the impact smears across the stereo field.
]]
local function playSpec(spec: EffectsConfig.SoundSpec, emitter: BasePart?)
	local id = pickId(spec)
	if id == nil then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = spec.Volume
	sound.PlaybackSpeed = (spec.Pitch or 1) + (math.random() * 2 - 1) * (spec.PitchJitter or 0)
	sound.SoundGroup = SoundBus.Get(spec.Group)

	-- A spatial sound is parented to the part that caused it, which is what makes an
	-- attacker behind you sound like they are behind you. Without an emitter there is no
	-- position to play from, so it falls back to flat rather than to silence.
	if spec.Spatial == true and emitter ~= nil then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = spec.RollOffMinDistance or 10
		sound.RollOffMaxDistance = spec.RollOffMaxDistance or 120
		sound.Parent = emitter
	else
		sound.Parent = SoundService
	end

	-- DSP, parented to the Sound so it dies with it. Order matters and is the config's:
	-- saturating before a reverb colours the whole tail, saturating after only dirties
	-- the dry signal.
	if spec.Effects ~= nil then
		for _, effect in spec.Effects do
			local ok, instance = pcall(Instance.new, effect.Class .. "SoundEffect")
			if ok then
				local unit = instance :: SoundEffect
				for property, value in effect.Props do
					-- Per property, so one bad name costs that setting and not the sound.
					pcall(function()
						(unit :: any)[property] = value
					end)
				end
				unit.Parent = sound
			end
		end
	end

	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()

	-- Belt and braces: a sound that never fires Ended (failed load, or an emitter that
	-- was destroyed mid-play) still goes away.
	task.delay(10, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)

	if spec.Layers ~= nil then
		for _, layer in spec.Layers do
			-- A layer inherits the parent's placement unless it overrides it. Without this
			-- a spatial impact plays its transient from the character and its sub flat
			-- from the listener, which pulls the two apart in the stereo field and is
			-- exactly the smearing the layering exists to avoid. Layers are written as
			-- bare `{ SoundId, Volume, Pitch }` on purpose — repeating the rolloff on
			-- every one would be noise nobody keeps in sync.
			local placed: EffectsConfig.SoundSpec = layer
			if layer.Spatial == nil and spec.Spatial == true then
				placed = {
					SoundId = layer.SoundId,
					Variants = layer.Variants,
					Volume = layer.Volume,
					Pitch = layer.Pitch,
					PitchJitter = layer.PitchJitter,
					Group = layer.Group or spec.Group,
					Spatial = true,
					RollOffMinDistance = layer.RollOffMinDistance or spec.RollOffMinDistance,
					RollOffMaxDistance = layer.RollOffMaxDistance or spec.RollOffMaxDistance,
					Effects = layer.Effects,
					Layers = layer.Layers,
				}
			end
			playSpec(placed, emitter)
		end
	end
end

--[[
	Pushes the player's saved volumes onto the mix buses.

	Called on Start and again whenever the profile changes, so moving a slider is audible
	before the menu has finished redrawing. Settings are stored 0-100 because that is what
	a slider shows; the bus takes 0-1.
]]
function EffectsController:_applyVolumes()
	local data = if ProfileController ~= nil then ProfileController:Get() else nil
	if data == nil then
		return
	end
	local settings = data.Settings
	SoundBus.SetVolumes(
		(settings.MasterVolume or 100) / 100,
		(settings.MusicVolume or 100) / 100,
		(settings.SfxVolume or 100) / 100
	)
end

--[[
	The local character's root, or nil while respawning. The default emitter for anything
	the local player does themselves.
]]
local function localRoot(): BasePart?
	local character = Players.LocalPlayer.Character
	if character == nil then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root ~= nil and root:IsA("BasePart") then root else nil
end

--[[
	Plays a configured sound.

	`emitter` is optional and is the part the sound comes from — the acting character's
	root, normally. Specs that are not `Spatial` ignore it, so callers can pass it
	unconditionally rather than knowing which sounds are positional.
]]
function EffectsController:Play(name: string, emitter: BasePart?)
	local data = if ProfileController ~= nil then ProfileController:Get() else nil
	-- Cheap gate. The Sfx bus is already at zero volume, but a muted player should not
	-- pay to decode a sound they will not hear.
	if data ~= nil and (data.Settings.SfxVolume or 100) <= 0 then
		return
	end

	local spec = (EffectsConfig.Sounds :: any)[name] :: EffectsConfig.SoundSpec?
	if spec == nil then
		return
	end

	if spec.Cooldown ~= nil then
		-- Keyed per emitter, not per effect. These handlers run for every visible
		-- character, so a single shared key would let the nearest runner's footsteps
		-- swallow everybody else's — the cooldown is there to stop one character
		-- machine-gunning, not to ration the sound across a crowd.
		local perEmitter = lastPlayed[name]
		if perEmitter == nil then
			perEmitter = setmetatable({}, { __mode = "k" }) :: any
			lastPlayed[name] = perEmitter
		end

		local key: Instance = emitter or NO_EMITTER
		local now = os.clock()
		if now - (perEmitter[key] or -math.huge) < spec.Cooldown then
			return
		end
		perEmitter[key] = now
	end

	playSpec(spec, emitter)
end

--[[
	Warms every configured id so the first punch of a session is not silent while the
	asset streams in. Fire-and-forget on a thread: a slow or failed preload must never
	hold up ignition.
]]
function EffectsController:_preload()
	local seen: { [string]: boolean } = {}
	local probes: { Instance } = {}

	local function collect(spec: EffectsConfig.SoundSpec)
		local ids: { string? } = spec.Variants or { spec.SoundId }
		for _, id in ids do
			if id ~= nil and id ~= "" and not seen[id] then
				seen[id] = true
				local probe = Instance.new("Sound")
				probe.SoundId = id
				table.insert(probes, probe)
			end
		end
		if spec.Layers ~= nil then
			for _, layer in spec.Layers do
				collect(layer)
			end
		end
	end

	for _, spec in EffectsConfig.Sounds do
		collect(spec :: EffectsConfig.SoundSpec)
	end

	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(probes)
		end)
		for _, probe in probes do
			probe:Destroy()
		end
	end)
end

--[[
	Floating damage number at the centre of the screen. Cheap stand-in for world-space
	numbers, and readable regardless of where the target is.
]]
--[[
	Pulses the hurt vignette, at a strength set by how much of your health that hit took.

	Scaled against max health rather than against an absolute number, so it means the
	same thing at every point on the progression curve: a quarter of your bar looks like
	a quarter of your bar whether that is 25 damage or 25 billion.
]]
function EffectsController:_flashHurt(damage: number)
	local vignette = hurtVignette
	if vignette == nil then
		return
	end

	local humanoid = nil
	local character = Players.LocalPlayer.Character
	if character ~= nil then
		humanoid = character:FindFirstChildOfClass("Humanoid")
	end
	local maxHealth = if humanoid ~= nil and humanoid.MaxHealth > 0 then humanoid.MaxHealth else 100
	local share = math.clamp(damage / maxHealth, 0, 1)

	-- A floor, because a hit that barely scratched you still has to register — the
	-- number alone is easy to miss when you are looking at the person throwing it.
	local peak = 0.62 - 0.42 * math.min(1, share * 3)
	vignette.BackgroundTransparency = peak
	TweenService:Create(
		vignette,
		TweenInfo.new(HURT_FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	):Play()
end

function EffectsController:_showDamage(amount: number, color: Color3, dealt: boolean?, reflected: boolean?)
	local layer = damageLayer
	if layer == nil then
		return
	end

	-- A large anime-style pop: it overshoots on entry, hangs fully readable, then
	-- accelerates upward while fading. Direction still separates dealt/taken damage.
	local side = if dealt then 0.62 else 0.38
	local group = Instance.new("CanvasGroup")
	group.Name = "AnimeDamage"
	group.AnchorPoint = Vector2.new(0.5, 0.5)
	group.Position = UDim2.fromScale(side + (math.random() - 0.5) * 0.04, 0.43)
	group.Size = UDim2.fromOffset(340, 112)
	group.BackgroundTransparency = 1
	group.GroupTransparency = 1
	group.Rotation = if dealt then math.random(-7, 2) else math.random(-2, 7)
	group.Parent = layer

	local scale = Instance.new("UIScale")
	scale.Scale = 0.42
	scale.Parent = group

	-- Eight cheap radial speed lines sell the impact without an imported texture.
	-- They expand during the number's overshoot and disappear before the readable hold.
	for index = 1, 8 do
		local streak = Instance.new("Frame")
		streak.Name = `ImpactLine{index}`
		streak.AnchorPoint = Vector2.new(0.5, 0.5)
		streak.Position = UDim2.fromScale(0.5, 0.5)
		streak.Size = UDim2.fromOffset(if reflected then 150 else 112, if index % 2 == 0 then 4 else 2)
		streak.BackgroundColor3 = if reflected then UI.Palette.FightToken else color
		streak.BackgroundTransparency = 0.18
		streak.BorderSizePixel = 0
		streak.Rotation = index * 45 + math.random(-7, 7)
		streak.ZIndex = 1
		streak.Parent = group
		TweenService:Create(streak, TweenInfo.new(0.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
			Size = UDim2.fromOffset(if reflected then 255 else 205, 1),
			BackgroundTransparency = 1,
		}):Play()
	end

	local shadow = UI.Label("Shadow", group)
	shadow.Position = UDim2.fromOffset(5, 7)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Font = UI.Font.Numeric
	shadow.TextSize = if reflected then 58 else 52
	shadow.TextXAlignment = Enum.TextXAlignment.Center
	shadow.TextColor3 = UI.Palette.CartoonInk
	shadow.TextTransparency = 0.1
	shadow.Text = `-{NumberFormat.Format(amount)}`
	shadow.ZIndex = 2

	local label = UI.Label("Damage", group)
	label.Size = UDim2.fromScale(1, 1)
	label.Font = UI.Font.Numeric
	label.TextSize = if reflected then 58 else 52
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = color
	label.TextStrokeColor3 = UI.Palette.CartoonInk
	label.TextStrokeTransparency = 0.05
	label.Text = `-{NumberFormat.Format(amount)}`
	label.ZIndex = 3

	if reflected then
		local flash = Instance.new("Frame")
		flash.Name = "ReflectionFlash"
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = UI.Palette.FightToken
		flash.BackgroundTransparency = 0.84
		flash.BorderSizePixel = 0
		flash.ZIndex = 1
		flash.Parent = layer
		local fade = TweenService:Create(flash, TweenInfo.new(0.18, Enum.EasingStyle.Quad), {
			BackgroundTransparency = 1,
		})
		fade.Completed:Connect(function()
			flash:Destroy()
		end)
		fade:Play()
	end

	local pop =
		TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Scale = 1.18,
		})
	local appear = TweenService:Create(group, TweenInfo.new(0.07, Enum.EasingStyle.Quad), {
		GroupTransparency = 0,
	})
	pop:Play()
	appear:Play()

	task.delay(0.12, function()
		if group.Parent == nil then
			return
		end
		TweenService:Create(scale, TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Scale = 1,
		}):Play()
	end)

	task.delay(0.48, function()
		if group.Parent == nil then
			return
		end
		local exit = TweenService:Create(
			group,
			TweenInfo.new(0.62, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
			{
				Position = group.Position - UDim2.fromOffset(if dealt then 34 else -34, 112),
				GroupTransparency = 1,
				Rotation = group.Rotation + (if dealt then -8 else 8),
			}
		)
		exit.Completed:Connect(function()
			group:Destroy()
		end)
		exit:Play()
	end)
end

-- A short combat explanation beneath the damage number. Ratio defenses are
-- intentionally dramatic, so the player must be told whether Back blocked the hit
-- or Core returned it instead of seeing a mysterious zero.
function EffectsController:_showCombatText(text: string, color: Color3, dealt: boolean?)
	local layer = damageLayer
	if layer == nil then
		return
	end

	local side = if dealt then 0.62 else 0.38
	local label = UI.Label("CombatBreakdown", layer)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(side, 0.5)
	label.Size = UDim2.fromOffset(230, 28)
	label.Font = UI.Font.Heading
	label.TextSize = 13
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.35
	label.Text = text

	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local rise = TweenService:Create(label, info, {
		Position = label.Position - UDim2.fromOffset(0, 24),
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	rise.Completed:Connect(function()
		label:Destroy()
	end)
	rise:Play()
end

--[[
	World-space payout card above the local avatar. It deliberately uses the amount
	the server says landed instead of reconstructing the multiplier stack locally.
]]
function EffectsController:_showTrainingGain(payload: Types.TrainingGain)
	local character = Players.LocalPlayer.Character
	local head = if character ~= nil then character:FindFirstChild("Head") else nil
	if head == nil or not head:IsA("BasePart") then
		return
	end

	local definition = StatConfig.Get(payload.StatId)
	local displayName = if definition ~= nil then definition.DisplayName else payload.StatId
	local color = if definition ~= nil then definition.Color else UI.Palette.Accent
	local iconName = if definition ~= nil then definition.Icon else "Train"

	-- Evict from the front: the oldest card is the one furthest up and faintest, so
	-- losing it costs the least.
	while #activeTrainingGains >= GAIN_STACK_LIMIT do
		local oldest = table.remove(activeTrainingGains, 1)
		if oldest ~= nil and oldest.Parent ~= nil then
			oldest:Destroy()
		end
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TrainingGain"
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(270, 66)
	-- Keep the changing payout beside the avatar instead of directly over the head.
	-- The bottom HUD card owns the persistent total; this is the quick side pop shown
	-- on each completed rep.
	billboard.StudsOffsetWorldSpace = Vector3.new(-3.6, 2.35, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 110
	billboard.LightInfluence = 0
	billboard.Parent = head
	table.insert(activeTrainingGains, billboard)

	local card = Instance.new("CanvasGroup")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.58)
	card.Size = UDim2.new(1, -8, 1, -8)
	card.BackgroundColor3 = UI.Palette.Backdrop
	card.BackgroundTransparency = 0.12
	card.BorderSizePixel = 0
	card.Parent = billboard

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = card

	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 2
	stroke.Transparency = 0.1
	stroke.Parent = card

	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, color:Lerp(UI.Palette.Backdrop, 0.78)),
		ColorSequenceKeypoint.new(1, UI.Palette.Backdrop),
	})
	gradient.Rotation = 8
	gradient.Parent = card

	local icon = Instance.new("Frame")
	icon.Name = "StatIcon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 10, 0.5, 0)
	icon.Size = UDim2.fromOffset(42, 42)
	icon.BackgroundTransparency = 1
	icon.Parent = card

	local iconAspect = Instance.new("UIAspectRatioConstraint")
	iconAspect.AspectRatio = 1
	iconAspect.Parent = icon
	Icons.Draw(iconName, icon, color, UI.Palette.Backdrop)

	local amount = UI.Label("Amount", card)
	amount.Position = UDim2.fromOffset(62, 5)
	amount.Size = UDim2.new(1, -72, 0, 32)
	amount.Font = UI.Font.Numeric
	amount.TextSize = 23
	amount.TextColor3 = color
	amount.TextStrokeColor3 = UI.Palette.CartoonInk
	amount.TextStrokeTransparency = 0.35
	amount.Text = `+{NumberFormat.FormatGain(payload.Amount)} {displayName}`

	local rate = UI.Label("Rate", card)
	rate.Position = UDim2.fromOffset(63, 35)
	rate.Size = UDim2.new(1, -73, 0, 18)
	rate.Font = UI.Font.Heading
	rate.TextSize = 11
	rate.TextColor3 = UI.Palette.TextMuted
	if payload.ComboGoal > 0 then
		if payload.ComboMultiplier > 1 then
			rate.Text =
				`{NumberFormat.FormatGain(payload.PerSecond)} / SEC  ·  FULL SET ×{NumberFormat.Format(
					payload.ComboMultiplier
				)}`
		else
			rate.Text =
				`{NumberFormat.FormatGain(payload.PerSecond)} / SEC  ·  SET {payload.Combo}/{payload.ComboGoal}`
		end
	else
		rate.Text = `{NumberFormat.FormatGain(payload.PerSecond)} / SEC  ·  BASE TRAINING`
	end

	-- Driven on a clock rather than by TweenService, which is worth the extra lines.
	--
	-- The obvious version is three tweens: fade in, rise, then a fade out with a
	-- DelayTime so the number holds at full opacity before it goes. That does not
	-- work. A tween reads its start value when it is played, not when it begins
	-- moving, and playing a second tween on a property cancels the first — so the
	-- delayed fade-out captured "transparency 1" from the fade-in that had barely
	-- started, cancelled it, and then spent its whole life interpolating 1 to 1. The
	-- card never appeared and never cleaned itself up. Measured, not guessed: five
	-- cards sat at transparency 1.00 above the player's head for as long as I watched.
	--
	-- One clock, three curves read off it, and a guaranteed end.
	local born = os.clock()
	local fadeInEnd = GAIN_FADE_IN / GAIN_LIFETIME
	local holdEnd = (GAIN_FADE_IN + GAIN_HOLD) / GAIN_LIFETIME
	local startY, endY = 0.58, 0.12

	local ticking: RBXScriptConnection? = nil
	local function finish()
		if ticking ~= nil then
			ticking:Disconnect()
			ticking = nil
		end
		local index = table.find(activeTrainingGains, billboard)
		if index ~= nil then
			table.remove(activeTrainingGains, index)
		end
		if billboard.Parent ~= nil then
			billboard:Destroy()
		end
	end

	card.GroupTransparency = 1
	-- Heartbeat, not RenderStepped. Every other per-frame loop in this codebase runs
	-- on Heartbeat or PreSimulation, and RenderStepped is refused outright in some
	-- client contexts — a card whose animation never ticks is a card that never fades
	-- and never cleans itself up, which is the failure this whole rewrite is fixing.
	ticking = RunService.Heartbeat:Connect(function()
		if billboard.Parent == nil then
			finish()
			return
		end

		local progress = (os.clock() - born) / GAIN_LIFETIME
		if progress >= 1 then
			finish()
			return
		end

		-- Cubic ease-out on the climb: quick off the head, drifting by the end.
		local eased = 1 - (1 - progress) ^ 3
		card.Position = UDim2.fromScale(0.5, startY + (endY - startY) * eased)

		if progress < fadeInEnd then
			-- In.
			card.GroupTransparency = 1 - progress / fadeInEnd
		elseif progress < holdEnd then
			-- Held fully opaque, which is what makes the fade afterwards read as
			-- deliberate rather than as the card being cut off.
			card.GroupTransparency = 0
		else
			-- Out, linearly. An eased fade spends most of its time nearly invisible,
			-- which is the abruptness this replaced.
			card.GroupTransparency = (progress - holdEnd) / (1 - holdEnd)
		end
	end)
end

function EffectsController:Init()
	ProfileController = Loader.Get("ProfileController")
	CombatController = Loader.Get("CombatController")
	ToastController = Loader.Get("ToastController")

	SoundBus.Ensure()

	-- Every button in the game clicks, from one place. UI lives in ReplicatedStorage and
	-- must not depend on a controller, so it exposes a hook and we fill it in rather than
	-- it reaching for us. The alternative — a Play call hand-wired onto each button — is
	-- what left most of the menu silent before.
	UI.SetPressListener(function()
		self:Play("UiClick")
	end)
end

function EffectsController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymEffects"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 20
	screen.Parent = playerGui

	--[[
		The red edge that pulses when you take a hit.

		A GUI frame rather than a Highlight on the body, and deliberately.
		StationHighlightController's header already documents why: Highlight is a real
		per-instance renderer cost and Roblox stops honouring them past a few dozen, and
		that controller is already using up to fourteen. A hit flash competing for that
		budget would silently stop appearing in exactly the crowded fight where it
		matters most. A frame costs nothing and reads faster than an outline anyway.

		Behind the damage numbers, and never interactive.
	]]
	local vignette = Instance.new("Frame")
	vignette.Name = "HurtVignette"
	vignette.BackgroundColor3 = EffectsConfig.HurtColor
	vignette.BackgroundTransparency = 1
	vignette.BorderSizePixel = 0
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.ZIndex = 0
	vignette.Active = false
	vignette.Parent = screen

	local gradient = Instance.new("UIGradient")
	-- Transparent through the middle and solid at both edges, so the colour sits around
	-- the frame instead of washing the whole screen red — a full-screen tint hides the
	-- person hitting you, which is the one thing you need to see.
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.28, 1),
		NumberSequenceKeypoint.new(0.72, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	gradient.Parent = vignette

	hurtVignette = vignette

	local layer = Instance.new("Frame")
	layer.Name = "Damage"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Parent = screen

	damageLayer = layer
end

function EffectsController:Start()
	self:_build()
	self:_preload()
	self:_applyVolumes()

	Net.Event("TrainingGain").OnClientEvent:Connect(function(payload: Types.TrainingGain)
		if
			type(payload) ~= "table"
			or type(payload.StatId) ~= "string"
			or type(payload.Amount) ~= "number"
			or type(payload.PerSecond) ~= "number"
			or type(payload.Combo) ~= "number"
			or type(payload.ComboGoal) ~= "number"
			or type(payload.ComboMultiplier) ~= "number"
			or payload.Amount <= 0
		then
			return
		end
		self:Play("Rep", localRoot())
		self:_showTrainingGain(payload)
	end)

	CombatController.Feedback:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end

		-- Both directions get a number now. The HUD used to write "You hit X for N" into
		-- a text log in the top-left corner, which is the one place a player in a fight
		-- is not looking; the corner is the minimap's, and the number belongs where the
		-- fight is.
		local damage = if type(payload.Damage) == "number" then math.max(0, payload.Damage) else 0
		local blocked = if type(payload.Blocked) == "number" then math.max(0, payload.Blocked) else 0
		local reflected = if type(payload.Reflected) == "number" then math.max(0, payload.Reflected) else 0
		local dealt = payload.Kind == "Hit"

		if payload.Kind == "Hit" or payload.Kind == "Hurt" then
			-- Reflection is intentionally explained with words only. Showing the returned
			-- amount as a second giant damage number made one punch look like two ordinary
			-- hits and obscured which player actually threw it.
			if damage > 0 and payload.IsReflection ~= true then
				self:Play(if dealt then "Hit" else "Hurt")
				if not dealt then
					self:_flashHurt(damage)
				end
				self:_showDamage(
					damage,
					if dealt then EffectsConfig.HitColor else EffectsConfig.HurtColor,
					dealt
				)
			end

			if payload.IsReflection == true then
				self:_showCombatText("CORE RETURN", UI.Palette.FightToken, dealt)
			elseif blocked > 0 or reflected > 0 then
				local pieces: { string } = {}
				if blocked > 0 then
					table.insert(pieces, `{NumberFormat.Format(blocked)} BLOCKED`)
				end
				if reflected > 0 then
					table.insert(pieces, "REFLECTED")
				end
				self:_showCombatText(table.concat(pieces, "  ·  "), UI.Palette.FightToken, dealt)
			elseif damage <= 0 then
				self:_showCombatText("NO DAMAGE", UI.Palette.TextMuted, dealt)
			end
		elseif payload.Kind == "Blocked" or payload.Kind == "Rejected" then
			-- A refusal is a sentence, not a number: "they are in a safe zone" has to
			-- be read, so it goes to the toast strip rather than over the crosshair.
			if ToastController ~= nil and type(payload.Reason) == "string" then
				ToastController:Show(payload.Reason)
			end
		end
	end)

	ProfileController.Changed:Connect(function(data: any)
		if data == nil then
			return
		end

		self:_applyVolumes()

		local rank = RankConfig.Get(Formulas.TotalPower(data.Stats))
		if lastRankId ~= nil and rank.Id ~= lastRankId then
			self:Play("RankUp")
		end
		lastRankId = rank.Id
	end)
end

return EffectsController
