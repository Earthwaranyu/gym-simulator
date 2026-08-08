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
local UserInputService = game:GetService("UserInputService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local StatConfig = require(ReplicatedStorage.Modules.StatConfig)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Types = require(ReplicatedStorage.Modules.Types)
local Icons = require(ReplicatedStorage.Modules.Icons)

-- Punch's cooldown, mirrored for the cooldown sweep. The server remains the
-- authority; this only decides when the pip looks ready.
local PUNCH_COOLDOWN = 0.6
local FEED_LINES = 4
-- A slot is a square big enough to hit with a thumb and small enough that five of
-- them plus their gaps stay narrower than the vitals panel above.
local SLOT_SIZE = 44
local SLOT_GAP = 6
-- How often a held mouse button re-tells the server it is still held. Comfortably
-- inside the server's activity window so holding never flickers off, and slow
-- enough that it costs nothing.
local PING_INTERVAL = 0.4
-- Which stat the fist belongs to. Named rather than inlined because two places
-- below branch on it, and "Arms" appearing twice as a literal is how those two
-- quietly disagree later.
local ARMS_STAT = "Arms"

local HudController = {
	Name = "HudController",
	Priority = 10,
}

local ProfileController: any = nil
local TrainingController: any = nil
local CombatController: any = nil
local MenuController: any = nil

type Slot = { Button: TextButton, Stroke: UIStroke, Number: TextLabel }

local slotButtons: { [Types.StatId]: Slot } = {}
-- Which muscle the left mouse button trains. Never nil once Start has run: the
-- click has to do something, so there is always a slot selected.
local selectedStat: Types.StatId = StatConfig.List[1].Id
local clicking = false
local powerLabel: TextLabel
local tokenLabel: TextLabel
local healthBar: UI.Bar
local comboLabel: TextLabel
local abilityLabel: TextLabel
local goalPanel: Frame
local goalName: TextLabel
local goalDetail: TextLabel
local goalBar: UI.Bar
local feedLabels: { TextLabel } = {}
local feedLines: { string } = {}

local lastPunchAt = -math.huge

function HudController:Init()
	ProfileController = Loader.Get("ProfileController")
	TrainingController = Loader.Get("TrainingController")
	CombatController = Loader.Get("CombatController")
	MenuController = Loader.Get("MenuController")
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

	-- Top-left: only the two global currencies. Muscle values live in the five-button
	-- training dock below, where each number is also a direct route to its location.
	--
	-- This was two stacked panels 250px tall. The compact header now leaves the
	-- world visible and the muscle-specific information sits with its action button.
	--
	-- y = 16 is 16 below Roblox's own top bar, not 16 below the screen edge, because
	-- this ScreenGui no longer ignores the inset — see the note where it is built.
	local summary = UI.Panel("Summary", screen)
	summary.Position = UDim2.fromOffset(16, 16)
	summary.Size = UDim2.fromOffset(300, 42)

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
	-- Shifted left by the glyph's width plus its gap, so the number and the mark sit
	-- beside each other rather than on top of each other.
	tokenLabel.Position = UDim2.new(1, -24, 0, 0)
	tokenLabel.Size = UDim2.new(0.4, -24, 1, 0)
	tokenLabel.TextXAlignment = Enum.TextXAlignment.Right
	tokenLabel.Font = UI.Font.Numeric
	tokenLabel.TextColor3 = UI.Palette.Token

	-- The dumbbell mark rather than the word "Tokens". The currency is named by its
	-- glyph everywhere it appears — the goal card's reward, the shop's prices, and
	-- here — so the three read as the same thing without spelling it out each time.
	local tokenGlyph = Instance.new("Frame")
	tokenGlyph.Name = "TokenGlyph"
	tokenGlyph.BackgroundTransparency = 1
	tokenGlyph.AnchorPoint = Vector2.new(1, 0.5)
	tokenGlyph.Position = UDim2.fromScale(1, 0.5)
	tokenGlyph.Size = UDim2.fromOffset(20, 20)
	tokenGlyph.Parent = headline
	Icons.Draw("Token", tokenGlyph, UI.Palette.Token, UI.Palette.Backdrop)

	-- Bottom-centre: which muscle the left mouse button is currently training.
	--
	-- This was five wide chips carrying each stat's name, value and multiplier. All
	-- of that is on the Info screen, and repeating it across the bottom of the
	-- screen was the largest thing in the HUD while being the least urgent. What is
	-- urgent is one bit of state: which slot the click is going to train. So the
	-- dock is five numbered squares and nothing else.
	local chips = UI.Panel("TrainingDock", screen)
	chips.AnchorPoint = Vector2.new(0.5, 1)
	chips.Position = UDim2.new(0.5, 0, 1, -12)
	chips.Size = UDim2.fromOffset(SLOT_SIZE * 5 + SLOT_GAP * 4 + 24, SLOT_SIZE + 20)
	chips.BackgroundTransparency = 0.16

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(SLOT_SIZE, SLOT_SIZE)
	grid.CellPadding = UDim2.fromOffset(SLOT_GAP, 0)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = chips

	for index, definition in StatConfig.List do
		local button = Instance.new("TextButton")
		button.Name = definition.Id
		button.LayoutOrder = index
		button.BackgroundColor3 = UI.Palette.Backdrop
		button.BackgroundTransparency = 0.08
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Text = ""
		button.Parent = chips

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 7)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = definition.Color
		stroke.Thickness = 2
		stroke.Transparency = 1
		stroke.Parent = button

		local number = UI.Label("Slot", button)
		number.Size = UDim2.fromScale(1, 1)
		number.Font = UI.Font.Numeric
		number.TextSize = 18
		number.TextXAlignment = Enum.TextXAlignment.Center
		number.Text = tostring(index)

		slotButtons[definition.Id] = { Button = button, Stroke = stroke, Number = number }

		-- Tapping a slot picks it, the same as pressing its number. It no longer
		-- opens anything: the station list moved to the Map button, because "where
		-- can I train this" is a question about the map.
		UI.Pressable(button, {
			OnPress = function()
				self:_select(definition.Id)
			end,
		})
	end

	-- Bottom-centre: the vitals the player watches while training and fighting.
	local vitals = UI.Panel("Vitals", screen)
	vitals.AnchorPoint = Vector2.new(0.5, 1)
	vitals.Position = UDim2.new(0.5, 0, 1, -84)
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

	-- Under the compact summary: combat feed. The right side belongs to the roster
	-- and Menu button, while the bottom belongs to the training dock and controls.
	local feed = UI.Panel("Feed", screen)
	feed.Position = UDim2.fromOffset(16, 68)
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

	-- Right-side objective card: the reference game's best UX idea is that the next
	-- useful action never requires opening a menu. This uses the real quest stream and
	-- keeps its own original dark gym styling.
	goalPanel = UI.Panel("MainGoal", screen)
	goalPanel.AnchorPoint = Vector2.new(1, 0)
	goalPanel.Position = UDim2.new(1, -16, 0, 102)
	goalPanel.Size = UDim2.fromOffset(260, 116)
	goalPanel.Visible = false

	local goalHeading = UI.Label("Heading", goalPanel)
	goalHeading.Size = UDim2.new(1, -76, 0, 18)
	goalHeading.Font = UI.Font.Heading
	goalHeading.TextSize = 13
	goalHeading.TextColor3 = UI.Palette.Token
	goalHeading.Text = "MAIN GOAL"

	local questButton = Instance.new("TextButton")
	questButton.Name = "OpenQuests"
	questButton.AnchorPoint = Vector2.new(1, 0)
	questButton.Position = UDim2.fromScale(1, 0)
	questButton.Size = UDim2.fromOffset(70, 24)
	questButton.BackgroundColor3 = UI.Palette.Token
	questButton.BorderSizePixel = 0
	questButton.AutoButtonColor = false
	questButton.Font = UI.Font.Heading
	questButton.TextSize = 11
	questButton.TextColor3 = UI.Palette.Backdrop
	questButton.Text = "QUESTS"
	questButton.Parent = goalPanel
	UI.Pressable(questButton)
	questButton.Activated:Connect(function()
		MenuController:Open("Quests")
	end)

	local questCorner = Instance.new("UICorner")
	questCorner.CornerRadius = UDim.new(0, 6)
	questCorner.Parent = questButton

	goalName = UI.Label("GoalName", goalPanel)
	goalName.Position = UDim2.fromOffset(0, 26)
	goalName.Size = UDim2.new(1, 0, 0, 22)
	goalName.Font = UI.Font.Heading
	goalName.TextSize = 15
	goalName.TextColor3 = UI.Palette.Text

	goalDetail = UI.Label("GoalDetail", goalPanel)
	goalDetail.Position = UDim2.fromOffset(0, 49)
	goalDetail.Size = UDim2.new(1, 0, 0, 20)
	goalDetail.TextSize = 12
	goalDetail.TextColor3 = UI.Palette.TextMuted
	goalDetail.TextTruncate = Enum.TextTruncate.AtEnd

	goalBar = UI.Bar("GoalProgress", UI.Palette.Token, goalPanel)
	goalBar.Root.Position = UDim2.fromOffset(0, 78)
end

--[[
	Picks the muscle the left mouse button trains, and paints the strip to say so.

	The selected slot is drawn in its own stat colour rather than in the shared
	accent: five slots that all light up yellow tell you something is selected but
	not which muscle it was, and the stat colours are already the game's wayfinding
	everywhere else — the machine highlights, the map pins, the Info rows.
]]
function HudController:_select(statId: Types.StatId)
	if StatConfig.Get(statId) == nil then
		return
	end
	selectedStat = statId

	for id, slot in slotButtons do
		local definition = StatConfig.Get(id)
		local chosen = id == statId
		slot.Button.BackgroundColor3 = if chosen
			then (if definition ~= nil then definition.Color else UI.Palette.Accent)
			else UI.Palette.Backdrop
		slot.Button.BackgroundTransparency = if chosen then 0.05 else 0.08
		slot.Stroke.Transparency = if chosen then 0 else 1
		slot.Number.TextColor3 = if chosen then UI.Palette.Backdrop else UI.Palette.TextMuted
	end
end

--[[
	Tells the server the click is happening.

	Deliberately a "still going" ping rather than "grant me a rep": the server owns
	the clock and pays by elapsed time, so spamming the button as fast as possible
	earns exactly the same as holding it. That is the whole reason the client sends
	no amount and the server trusts no number from here.
]]
function HudController:_trainPing()
	Net.Event("ManualTrain"):FireServer(selectedStat)
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

function HudController:_refreshGoal(view: { any })
	-- Training is always the clearest first objective. The quest service may discover
	-- module files in any order, so choose deliberately instead of accidentally putting
	-- a three-player PvP goal in front of someone who has just spawned alone.
	local priority = { DailyReps = 1, FirstMillion = 2, DailyKnockouts = 3 }
	local selected = nil
	local selectedPriority = math.huge
	for _, quest in view do
		if type(quest) == "table" and quest.Complete ~= true then
			local questPriority = priority[tostring(quest.Id)] or 100
			if questPriority < selectedPriority then
				selected = quest
				selectedPriority = questPriority
			end
		end
	end
	selected = selected or view[1]
	if type(selected) ~= "table" then
		goalPanel.Visible = false
		return
	end

	local progress = if type(selected.Progress) == "number" then math.max(0, selected.Progress) else 0
	local target = if type(selected.Goal) == "number" then math.max(1, selected.Goal) else 1
	goalPanel.Visible = true
	goalName.Text = tostring(selected.DisplayName or "Training Goal")
	goalDetail.Text = tostring(selected.Description or "Keep training")
	goalBar.Set(
		math.clamp(progress / target, 0, 1),
		`{NumberFormat.Format(progress)} / {NumberFormat.Format(target)}  ·  +{NumberFormat.Format(
			selected.TokenReward or 0
		)} tokens`
	)
end

function HudController:_refreshProfile()
	local data = ProfileController:Get()
	if data == nil then
		return
	end

	powerLabel.Text = `POWER  {NumberFormat.Format(Formulas.TotalPower(data.Stats))}`
	tokenLabel.Text = `Tokens  {NumberFormat.Format(data.Tokens)}`
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

	Net.Event("QuestsChanged").OnClientEvent:Connect(function(view: any)
		if type(view) == "table" then
			self:_refreshGoal(view)
		end
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

	self:_select(selectedStat)

	-- Number keys pick a slot, matching the numbers printed on it.
	--
	-- Enum.KeyCode.One..Five rather than indexing the enum by the digit character:
	-- `Enum.KeyCode["1"]` is nil, so the old loop silently bound nothing.
	local DIGITS = {
		Enum.KeyCode.One,
		Enum.KeyCode.Two,
		Enum.KeyCode.Three,
		Enum.KeyCode.Four,
		Enum.KeyCode.Five,
	}

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed then
			return
		end

		for index, definition in StatConfig.List do
			if DIGITS[index] ~= nil and input.KeyCode == DIGITS[index] then
				self:_select(definition.Id)
				return
			end
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			clicking = true
			-- Arms is the fist, so a click that has someone in reach is a punch as
			-- well as a rep. CombatService rejects it if the target is out of range
			-- or immune, and the training ping is unaffected either way.
			if selectedStat == ARMS_STAT then
				CombatController:Attack()
			end
			self:_trainPing()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			clicking = false
		end
	end)

	-- Holding the button has to keep paying, and the server's window is short so it
	-- can tell "stopped clicking" from "between clicks". Re-ping while held.
	task.spawn(function()
		while true do
			task.wait(PING_INTERVAL)
			if clicking then
				self:_trainPing()
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		self:_refreshVitals()
	end)
end

return HudController
