--!strict
--[[
	EffectsController — sound and screen feedback.

	Everything is driven off events the game already fires, so no system had to be
	modified to make noise. Entries with a blank SoundId are skipped, which is why the
	game is silent but functional until real asset ids are pasted into EffectsConfig.

	Exercise-motion sounds are generated locally from the pose's own RepInterval. The
	server's stat award is deliberately independent and lands once per second; varied
	animation pace should sound natural without changing progression cadence.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local EffectsConfig = require(ReplicatedStorage.Modules.EffectsConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
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
local TrainingController: any = nil
local CombatController: any = nil
local ToastController: any = nil

local lastRepSoundAt = 0
local lastRankId: string? = nil
local damageLayer: Frame? = nil
local activeTrainingGain: BillboardGui? = nil

--[[
	Plays a configured sound, or does nothing if it has no asset id yet.
	Sounds are one-shot and clean themselves up, so nothing accumulates in SoundService.
]]
function EffectsController:Play(name: string)
	local data = if ProfileController ~= nil then ProfileController:Get() else nil
	if data ~= nil and data.Settings.SfxEnabled == false then
		return
	end

	local spec = (EffectsConfig.Sounds :: any)[name] :: EffectsConfig.SoundSpec?
	if spec == nil or spec.SoundId == "" then
		return
	end

	local sound = Instance.new("Sound")
	sound.SoundId = spec.SoundId
	sound.Volume = spec.Volume
	sound.PlaybackSpeed = spec.Pitch + (math.random() * 2 - 1) * spec.PitchJitter
	sound.Parent = SoundService

	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	sound:Play()

	-- Belt and braces: a sound that never fires Ended (failed load) still goes away.
	task.delay(10, function()
		if sound.Parent ~= nil then
			sound:Destroy()
		end
	end)
end

--[[
	Floating damage number at the centre of the screen. Cheap stand-in for world-space
	numbers, and readable regardless of where the target is.
]]
function EffectsController:_showDamage(amount: number, color: Color3, dealt: boolean?)
	local layer = damageLayer
	if layer == nil then
		return
	end

	-- Damage you dealt rises on one side of the crosshair, damage you took on the
	-- other. They used to share the middle, which in a two-way fight produced one
	-- unreadable pile of numbers with no way to tell whose was whose.
	local side = if dealt then 0.62 else 0.38
	local label = UI.Label("Damage", layer)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(side + (math.random() - 0.5) * 0.06, 0.44)
	label.Size = UDim2.fromOffset(160, 34)
	label.Font = UI.Font.Numeric
	label.TextSize = if dealt then 22 else 26
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.Text = `-{NumberFormat.Format(amount)}`

	local info =
		TweenInfo.new(EffectsConfig.DAMAGE_NUMBER_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local rise = TweenService:Create(label, info, {
		Position = label.Position - UDim2.fromOffset(0, EffectsConfig.DAMAGE_NUMBER_RISE * 10),
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

	-- Stat ticks are a status readout, not a combat-number pile. Replace the previous
	-- card before drawing the next one so Heartbeat jitter can never leave two muscle
	-- gains occupying the same space.
	local previous = activeTrainingGain
	activeTrainingGain = nil
	if previous ~= nil then
		previous:Destroy()
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "TrainingGain"
	billboard.Adornee = head
	billboard.Size = UDim2.fromOffset(310, 66)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.25, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 110
	billboard.LightInfluence = 0
	billboard.Parent = head
	activeTrainingGain = billboard

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
	amount.TextStrokeColor3 = Color3.new(0, 0, 0)
	amount.TextStrokeTransparency = 0.35
	amount.Text = `+{NumberFormat.Format(payload.Amount)} {displayName}`

	local rate = UI.Label("Rate", card)
	rate.Position = UDim2.fromOffset(63, 35)
	rate.Size = UDim2.new(1, -73, 0, 18)
	rate.Font = UI.Font.Heading
	rate.TextSize = 11
	rate.TextColor3 = UI.Palette.TextMuted
	if payload.ComboGoal > 0 then
		if payload.ComboMultiplier > 1 then
			rate.Text = `{NumberFormat.Format(payload.PerSecond)} / SEC  ·  FULL SET ×{NumberFormat.Format(
				payload.ComboMultiplier
			)}`
		else
			rate.Text =
				`{NumberFormat.Format(payload.PerSecond)} / SEC  ·  SET {payload.Combo}/{payload.ComboGoal}`
		end
	else
		rate.Text = `{NumberFormat.Format(payload.PerSecond)} / SEC  ·  BASE TRAINING`
	end

	-- Finish comfortably before the next one-second server tick. Replacement above is
	-- still the hard guarantee when network packets arrive unusually close together.
	local info = TweenInfo.new(0.78, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local rise = TweenService:Create(card, info, {
		Position = UDim2.fromScale(0.5, 0.18),
		GroupTransparency = 1,
	})

	rise.Completed:Connect(function()
		if activeTrainingGain == billboard then
			activeTrainingGain = nil
		end
		if billboard.Parent ~= nil then
			billboard:Destroy()
		end
	end)
	rise:Play()
end

function EffectsController:Init()
	ProfileController = Loader.Get("ProfileController")
	TrainingController = Loader.Get("TrainingController")
	CombatController = Loader.Get("CombatController")
	ToastController = Loader.Get("ToastController")
end

function EffectsController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymEffects"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 20
	screen.Parent = playerGui

	local layer = Instance.new("Frame")
	layer.Name = "Damage"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Parent = screen

	damageLayer = layer
end

function EffectsController:Start()
	self:_build()

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
		if payload.Kind == "Hit" then
			self:Play("Hit")
			self:_showDamage(payload.Damage or 0, EffectsConfig.HitColor, true)
		elseif payload.Kind == "Hurt" then
			self:Play("Hurt")
			self:_showDamage(payload.Damage or 0, EffectsConfig.HurtColor, false)
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

		local rank = RankConfig.Get(Formulas.TotalPower(data.Stats))
		if lastRankId ~= nil and rank.Id ~= lastRankId then
			self:Play("RankUp")
		end
		lastRankId = rank.Id
	end)

	-- Rep ticks, paced locally from the machine's own interval.
	RunService.Heartbeat:Connect(function()
		local state = TrainingController:GetState()
		if state.StationId == nil then
			return
		end

		local definition = EquipmentConfig.Get(state.StationId)
		if definition == nil then
			return
		end

		local now = os.clock()
		if now - lastRepSoundAt >= definition.RepInterval then
			lastRepSoundAt = now
			self:Play("Rep")
		end
	end)
end

return EffectsController
