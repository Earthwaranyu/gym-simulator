--!strict
--[[
	HudController — the in-game heads-up display.

	Covers checklist 47 (stats, power, tokens, combo) and 49 (health and the ability
	cooldown), because they share one ScreenGui and one update pass.

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
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Types = require(ReplicatedStorage.Modules.Types)

-- Punch's cooldown, mirrored for the cooldown sweep. The server remains the
-- authority; this only decides when the pip looks ready.
local PUNCH_COOLDOWN = 0.6
local FEED_LINES = 4
-- Wide enough for the worst case a chip has to hold: a stat in the trillions with
-- a multiplier beside it, which is about 110px of text at this size.
local CHIP_WIDTH = 116
local STATS_WIDTH = CHIP_WIDTH * 3 + 8 + 24

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
	-- Respect the inset rather than ignore it. Ignoring it puts y = 0 at the true
	-- top of the screen, which is *underneath* Roblox's own top bar — the summary
	-- panel used to sit at y = 16 and was clipped by it on every device. The inset
	-- is 58px here and is not a constant across devices, so the fix is to let
	-- Roblox place the origin rather than to guess an offset.
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = playerGui

	-- Every offset below was chosen against a 720-tall screen. This is what makes
	-- them mean the same thing on a phone and on a monitor, and it is shared with
	-- the button bar so the two cannot drift into each other.
	UI.ScaleWithViewport(screen)

	-- Top-left: power, tokens, and every stat, in one block.
	--
	-- This was two stacked panels 250px tall, which owned the whole left column and
	-- left the button bar nowhere to go. Stats are a wrapping row of chips now
	-- instead of five full-width rows: the numbers are the same, they are read at a
	-- glance rather than studied, and the block is a third of the height.
	--
	-- y = 16 is 16 below Roblox's own top bar, not 16 below the screen edge, because
	-- this ScreenGui no longer ignores the inset — see the note where it is built.
	local summary = UI.Panel("Summary", screen)
	summary.Position = UDim2.fromOffset(16, 16)
	summary.Size = UDim2.fromOffset(STATS_WIDTH, 84)

	UI.VerticalList(summary, 4)

	local headline = Instance.new("Frame")
	headline.Name = "Headline"
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, 0, 0, 26)
	headline.LayoutOrder = 1
	headline.Parent = summary

	powerLabel = UI.Label("Power", headline)
	powerLabel.Size = UDim2.fromScale(0.6, 1)
	powerLabel.Font = UI.Font.Numeric
	powerLabel.TextSize = 21
	powerLabel.TextColor3 = UI.Palette.Power

	tokenLabel = UI.Label("Tokens", headline)
	tokenLabel.AnchorPoint = Vector2.new(1, 0)
	tokenLabel.Position = UDim2.fromScale(1, 0)
	tokenLabel.Size = UDim2.fromScale(0.4, 1)
	tokenLabel.TextXAlignment = Enum.TextXAlignment.Right
	tokenLabel.TextColor3 = UI.Palette.Token

	-- One chip per stat, generated from config, wrapping onto as many lines as it
	-- takes. A sixth stat still needs no edit here.
	local chips = Instance.new("Frame")
	chips.Name = "Stats"
	chips.BackgroundTransparency = 1
	chips.Size = UDim2.new(1, 0, 0, 44)
	chips.LayoutOrder = 2
	chips.Parent = summary

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(CHIP_WIDTH, 20)
	grid.CellPadding = UDim2.fromOffset(4, 2)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = chips

	for index, definition in StatConfig.List do
		local chip = UI.Label(definition.Id, chips)
		chip.LayoutOrder = index
		chip.TextSize = 13
		chip.TextColor3 = definition.Color
		-- Numbers here run to the trillions. Truncating keeps a long one inside its
		-- own chip rather than letting it run over the stat next to it.
		chip.TextTruncate = Enum.TextTruncate.AtEnd
		statLabels[definition.Id] = chip
	end

	-- Bottom-centre: the vitals the player watches while training and fighting.
	local vitals = UI.Panel("Vitals", screen)
	vitals.AnchorPoint = Vector2.new(0.5, 1)
	vitals.Position = UDim2.new(0.5, 0, 1, -16)
	vitals.Size = UDim2.fromOffset(380, 94)

	UI.VerticalList(vitals, 6)

	healthBar = UI.Bar("Health", UI.Palette.Health, vitals)
	healthBar.Root.LayoutOrder = 1

	comboLabel = UI.Label("Combo", vitals)
	comboLabel.Size = UDim2.new(1, 0, 0, 20)
	comboLabel.TextColor3 = UI.Palette.Combo
	comboLabel.LayoutOrder = 2

	abilityLabel = UI.Label("Ability", vitals)
	abilityLabel.Size = UDim2.new(1, 0, 0, 20)
	abilityLabel.TextColor3 = UI.Palette.TextMuted
	abilityLabel.LayoutOrder = 3

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

		-- A chip has room for the name and the number. The multiplier moves to the
		-- tooltip-ish second line only when there is one to show, so an unupgraded
		-- stat is not carrying a permanent "x1.00".
		local suffix = if level > 0
			then ` <font color="#8A93A8">x{string.format("%.1f", Formulas.MultiplierValue(level))}</font>`
			else ""
		label.Text = `<b>{name}</b> {NumberFormat.Format(data.Stats[statId] or 0)}{suffix}`
	end
end

function HudController:_refreshVitals()
	local state = TrainingController:GetState()
	local stagger = TrainingController:GetStaggerRemaining()

	if stagger > 0 then
		comboLabel.Text = `Knocked off the machine — {string.format("%.1f", stagger)}s`
		comboLabel.TextColor3 = UI.Palette.Danger
	elseif state.StationId ~= nil then
		local definition = EquipmentConfig.Get(state.StationId)
		local name = if definition ~= nil then definition.DisplayName else state.StationId
		local combo = math.min(2, 1 + state.Combo * 0.02)
		comboLabel.Text =
			`{name}  —  combo x{string.format("%.2f", combo)} ({state.Combo} reps)  —  Space or hold E to stop`
		comboLabel.TextColor3 = UI.Palette.Combo
	else
		comboLabel.Text = "Hold E at a machine to start training"
		comboLabel.TextColor3 = UI.Palette.TextMuted
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
