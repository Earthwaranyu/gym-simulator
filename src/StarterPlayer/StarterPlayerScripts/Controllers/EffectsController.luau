--!strict
--[[
	EffectsController — sound and screen feedback.

	Everything is driven off events the game already fires, so no system had to be
	modified to make noise. Entries with a blank SoundId are skipped, which is why the
	game is silent but functional until real asset ids are pasted into EffectsConfig.

	Rep ticks are generated locally from the machine's own RepInterval rather than from
	a server event. The server throttles training pushes to four a second precisely so
	it is not sending a packet per rep, and audio does not justify undoing that.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local EffectsConfig = require(ReplicatedStorage.Modules.EffectsConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

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

--[[
	Plays a configured sound, or does nothing if it has no asset id yet.
	Sounds are one-shot and clean themselves up, so nothing accumulates in SoundService.
]]
function EffectsController:Play(name: string)
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
