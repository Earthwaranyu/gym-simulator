--!strict
--[[
	HudController — the in-game heads-up display.

	Covers checklist 47 (stats, power, tokens, stamina, combo) and 49 (health and the
	ability cooldown), because they share one ScreenGui and one update pass.

	Stat rows are generated from StatConfig rather than hand-written, so adding a
	sixth stat makes a sixth row appear with no edit here. Values come from
	ProfileController's replicated view, never from local guesses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local UI = require(ReplicatedStorage.Modules.UI)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Types = require(ReplicatedStorage.Modules.Types)

-- Punch's cooldown, mirrored for the cooldown sweep. The server remains the
-- authority; this only decides when the pip looks ready.
local PUNCH_COOLDOWN = 0.6
local FEED_LINES = 4

local HudController = {
	Name = "HudController",
	Priority = 10,
}

local ProfileController: any = nil
local TrainingController: any = nil
local CombatController: any = nil

local statLabels: { [Types.StatId]: TextLabel } = {}
local powerLabel: TextLabel
local tokenLabel: TextLabel
local staminaBar: UI.Bar
local healthBar: UI.Bar
local comboLabel: TextLabel
local abilityLabel: TextLabel
local feedLabels: { TextLabel } = {}
local feedLines: { string } = {}

local lastPunchAt = -math.huge

function HudController:Init()
	ProfileController = Loader.Get("ProfileController")
	TrainingController = Loader.Get("TrainingController")
	CombatController = Loader.Get("CombatController")
end

function HudController:_build()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local screen = Instance.new("ScreenGui")
	screen.Name = "GymHud"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui

	-- Top-left: identity block — power and tokens.
	local summary = UI.Panel("Summary", screen)
	summary.Position = UDim2.fromOffset(16, 16)
	summary.Size = UDim2.fromOffset(230, 74)

	UI.VerticalList(summary, 4)

	powerLabel = UI.Label("Power", summary)
	powerLabel.Size = UDim2.new(1, 0, 0, 26)
	powerLabel.Font = UI.Font.Numeric
	powerLabel.TextSize = 22
	powerLabel.TextColor3 = UI.Palette.Power
	powerLabel.LayoutOrder = 1

	tokenLabel = UI.Label("Tokens", summary)
	tokenLabel.Size = UDim2.new(1, 0, 0, 20)
	tokenLabel.TextColor3 = UI.Palette.Token
	tokenLabel.LayoutOrder = 2

	-- Left: one row per stat, generated from config.
	local stats = UI.Panel("Stats", screen)
	stats.Position = UDim2.fromOffset(16, 102)
	stats.Size = UDim2.fromOffset(230, 26 * StatConfig.Count() + 20)

	UI.VerticalList(stats, 2)

	for index, definition in StatConfig.List do
		local row = UI.Label(definition.Id, stats)
		row.Size = UDim2.new(1, 0, 0, 24)
		row.LayoutOrder = index
		row.TextColor3 = definition.Color
		statLabels[definition.Id] = row
	end

	-- Bottom-centre: the vitals the player watches while training and fighting.
	local vitals = UI.Panel("Vitals", screen)
	vitals.AnchorPoint = Vector2.new(0.5, 1)
	vitals.Position = UDim2.new(0.5, 0, 1, -16)
	vitals.Size = UDim2.fromOffset(380, 116)

	UI.VerticalList(vitals, 6)

	healthBar = UI.Bar("Health", UI.Palette.Health, vitals)
	healthBar.Root.LayoutOrder = 1

	staminaBar = UI.Bar("Stamina", UI.Palette.Stamina, vitals)
	staminaBar.Root.LayoutOrder = 2

	comboLabel = UI.Label("Combo", vitals)
	comboLabel.Size = UDim2.new(1, 0, 0, 20)
	comboLabel.TextColor3 = UI.Palette.Combo
	comboLabel.LayoutOrder = 3

	abilityLabel = UI.Label("Ability", vitals)
	abilityLabel.Size = UDim2.new(1, 0, 0, 20)
	abilityLabel.TextColor3 = UI.Palette.TextMuted
	abilityLabel.LayoutOrder = 4

	-- Bottom-right: combat feed.
	local feed = UI.Panel("Feed", screen)
	feed.AnchorPoint = Vector2.new(1, 1)
	feed.Position = UDim2.new(1, -16, 1, -16)
	feed.Size = UDim2.fromOffset(260, 20 * FEED_LINES + 20)
	feed.BackgroundTransparency = 0.45

	UI.VerticalList(feed, 2)

	for index = 1, FEED_LINES do
		local line = UI.Label(`Line{index}`, feed)
		line.Size = UDim2.new(1, 0, 0, 18)
		line.TextSize = 14
		line.LayoutOrder = index
		line.TextColor3 = UI.Palette.TextMuted
		feedLabels[index] = line
	end
end

function HudController:_pushFeed(text: string)
	table.insert(feedLines, 1, text)
	while #feedLines > FEED_LINES do
		table.remove(feedLines)
	end

	for index, label in feedLabels do
		label.Text = feedLines[index] or ""
	end
end

function HudController:_refreshProfile()
	local data = ProfileController:Get()
	if data == nil then
		return
	end

	powerLabel.Text = `POWER  {NumberFormat.Format(Formulas.TotalPower(data.Stats))}`
	tokenLabel.Text = `Tokens  {NumberFormat.Format(data.Tokens)}`

	for statId, label in statLabels do
		local definition = StatConfig.Get(statId)
		local name = if definition ~= nil then definition.DisplayName else statId
		local level = data.MultiplierLevels[statId] or 0
		local multiplier = Formulas.MultiplierValue(level)

		local suffix = if level > 0
			then ` <font color="#8A93A8">x{string.format("%.2f", multiplier)}</font>`
			else ""
		label.Text = `{name}  {NumberFormat.Format(data.Stats[statId] or 0)}{suffix}`
	end
end

function HudController:_refreshVitals()
	local state = TrainingController:GetState()

	local maxStamina = math.max(1, state.MaxStamina)
	staminaBar.Set(
		state.Stamina / maxStamina,
		`STAMINA  {math.floor(state.Stamina)} / {math.floor(state.MaxStamina)}`
	)

	if state.StationId ~= nil then
		local combo = math.min(2, 1 + state.Combo * 0.02)
		comboLabel.Text =
			`Training {state.StationId}  —  combo x{string.format("%.2f", combo)} ({state.Combo} reps)`
	else
		comboLabel.Text = "Walk up to a machine and press E to train"
	end

	local character = Players.LocalPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil

	if humanoid ~= nil and humanoid.MaxHealth > 0 then
		healthBar.Set(
			humanoid.Health / humanoid.MaxHealth,
			`HEALTH  {math.floor(humanoid.Health)} / {math.floor(humanoid.MaxHealth)}`
		)
	else
		healthBar.Set(0, "HEALTH  —")
	end

	local remaining = PUNCH_COOLDOWN - (os.clock() - lastPunchAt)
	if remaining > 0 then
		abilityLabel.Text = `[F] Punch  —  {string.format("%.1f", remaining)}s`
		abilityLabel.TextColor3 = UI.Palette.TextMuted
	else
		local target = CombatController:FindTarget()
		if target ~= nil then
			abilityLabel.Text = `[F] Punch  —  {target.Name}`
			abilityLabel.TextColor3 = UI.Palette.Danger
		else
			abilityLabel.Text = "[F] Punch  —  ready"
			abilityLabel.TextColor3 = UI.Palette.Accent
		end
	end
end

function HudController:Start()
	self:_build()
	self:_refreshProfile()

	ProfileController.Changed:Connect(function()
		self:_refreshProfile()
	end)

	CombatController.Feedback:Connect(function(payload: any)
		if type(payload) ~= "table" then
			return
		end

		if payload.Kind == "Hit" then
			lastPunchAt = os.clock()
			self:_pushFeed(`You hit {payload.Victim} for {NumberFormat.Format(payload.Damage)}`)
		elseif payload.Kind == "Hurt" then
			self:_pushFeed(`{payload.Attacker} hit you for {NumberFormat.Format(payload.Damage)}`)
		elseif payload.Kind == "Blocked" or payload.Kind == "Rejected" then
			self:_pushFeed(tostring(payload.Reason))
		end
	end)

	RunService.RenderStepped:Connect(function()
		self:_refreshVitals()
	end)
end

return HudController
