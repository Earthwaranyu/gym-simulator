--!strict
--[[
	WeightController — recognition-first working-weight selector.

	The current load is the largest information on the panel. Every positive load is
	an explicit added-plate preset in one scrolling list. Rows explain CURRENT,
	RECOMMENDED, LIGHTER, AVAILABLE, or the exact stat requirement in text; colour is
	only a second channel. The server remains authoritative for every selection.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local Types = require(ReplicatedStorage.Modules.Types)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local WeightConfig = require(ReplicatedStorage.Modules.WeightConfig)

local WeightController = {
	Name = "WeightController",
	Priority = 9,
}

type PresetRow = {
	button: TextButton,
	load: TextLabel,
	state: TextLabel,
	stroke: UIStroke,
	-- An overlay that blinks when the row is clicked. It owns no other state, which is
	-- the point: _render rewrites the button's own background and stroke on every push,
	-- so animating either of those would be wiped mid-blink.
	flash: Frame,
	targetKg: number,
}

local FLASH_PEAK = 0.75
local FLASH_FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--[[
	Answer the click, whatever the click turns out to mean.

	Choosing the load you are already on changes nothing: the server writes back the same
	number and the panel redraws identically, so without this the button looked broken to
	anyone who pressed it twice. A control has to admit it heard you even when the answer
	is "that is already the case".
]]
local function acknowledge(row: PresetRow)
	row.flash.BackgroundTransparency = FLASH_PEAK
	TweenService:Create(row.flash, FLASH_FADE, { BackgroundTransparency = 1 }):Play()
end

local TrainingController: any = nil
local root: Frame
local currentCaption: TextLabel
local weightLabel: TextLabel
local meaningLabel: TextLabel
local bonusLabel: TextLabel
local guidanceLabel: TextLabel
local rangeLabel: TextLabel
local presetScroller: ScrollingFrame
local presetLayout: UIListLayout
local autoButton: TextButton
local resetButton: TextButton
local statusLabel: TextLabel
local presetRows: { PresetRow } = {}
local renderedRangeKey = ""
local lastStationId: string? = nil

local PER_HAND: { [string]: boolean } = {
	Dumbbells = true,
	InclinePress = true,
	HammerCurl = true,
}

local MACHINE_RESISTANCE: { [string]: boolean } = {
	PecDeck = true,
	CableCrossover = true,
	TricepsPushdown = true,
	SeatedRow = true,
	LatPulldown = true,
	CableCrunch = true,
	WoodChop = true,
	LegPress = true,
	LegExtension = true,
	HamstringCurl = true,
	CalfRaise = true,
}

local function makeButton(name: string, text: string, parent: Instance): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = UI.Dark.Backdrop
	button.BackgroundTransparency = 0.08
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = UI.Font.Heading
	button.TextColor3 = UI.Dark.Text
	button.TextSize = 14
	button.Text = text
	button.Parent = parent

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI.Dark.GlassStroke
	stroke.Transparency = 0.55
	stroke.Parent = button

	UI.Pressable(button)
	return button
end

local function loadMeaning(stationId: string, weightKg: number): string
	if PER_HAND[stationId] then
		return if weightKg <= 0
			then "BARE IRON HANDLES"
			else `{NumberFormat.Format(weightKg)} KG ON EACH HAND`
	elseif MACHINE_RESISTANCE[stationId] then
		return if weightKg <= 0
			then "UNLOADED MACHINE"
			else `{NumberFormat.Format(weightKg)} KG MACHINE RESISTANCE`
	end
	return if weightKg <= 0
		then "BARE EQUIPMENT — NO PLATES"
		else `{NumberFormat.Format(weightKg)} KG TOTAL ADDED LOAD`
end

function WeightController:Init()
	TrainingController = Loader.Get("TrainingController")
end

function WeightController:_build()
	local screen = Instance.new("ScreenGui")
	screen.Name = "TrainingLoadGui"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	UI.ScaleWithViewport(screen)

	root = UI.Panel("LoadSelector", screen)
	root.AnchorPoint = Vector2.new(1, 0.5)
	root.Position = UDim2.new(1, -24, 0.5, 12)
	root.Size = UDim2.fromOffset(330, 566)
	root.BackgroundTransparency = 0.03
	root.Visible = false

	local heading = UI.Label("Heading", root)
	heading.Size = UDim2.new(1, 0, 0, 26)
	heading.Font = UI.Font.Heading
	heading.TextSize = 21
	heading.Text = "WEIGHTS"

	currentCaption = UI.Label("CurrentCaption", root)
	currentCaption.Position = UDim2.fromOffset(0, 34)
	currentCaption.Size = UDim2.new(1, 0, 0, 18)
	currentCaption.Text = "CURRENT WORKING WEIGHT"
	currentCaption.TextColor3 = UI.Dark.TextMuted
	currentCaption.TextSize = 12

	weightLabel = UI.Label("CurrentWeight", root)
	weightLabel.Position = UDim2.fromOffset(0, 50)
	weightLabel.Size = UDim2.new(1, 0, 0, 52)
	weightLabel.Font = UI.Font.Numeric
	weightLabel.TextSize = 42
	weightLabel.TextColor3 = UI.Dark.Text

	meaningLabel = UI.Label("Meaning", root)
	meaningLabel.Position = UDim2.fromOffset(0, 104)
	meaningLabel.Size = UDim2.new(1, 0, 0, 18)
	meaningLabel.TextSize = 12
	meaningLabel.TextColor3 = UI.Dark.Text

	bonusLabel = UI.Label("Bonus", root)
	bonusLabel.Position = UDim2.fromOffset(0, 128)
	bonusLabel.Size = UDim2.new(1, 0, 0, 20)
	bonusLabel.TextXAlignment = Enum.TextXAlignment.Center
	bonusLabel.Font = UI.Font.Numeric
	bonusLabel.TextSize = 13
	bonusLabel.TextColor3 = UI.Dark.Power

	guidanceLabel = UI.Label("Guidance", root)
	guidanceLabel.Position = UDim2.fromOffset(0, 154)
	guidanceLabel.Size = UDim2.new(1, 0, 0, 38)
	guidanceLabel.TextXAlignment = Enum.TextXAlignment.Center
	guidanceLabel.TextWrapped = true
	guidanceLabel.Font = UI.Font.Heading
	guidanceLabel.TextSize = 13

	local listHeading = UI.Label("PresetHeading", root)
	listHeading.Position = UDim2.fromOffset(0, 202)
	listHeading.Size = UDim2.new(0.5, 0, 0, 18)
	listHeading.Text = "ADD PLATES"
	listHeading.Font = UI.Font.Heading
	listHeading.TextSize = 13

	rangeLabel = UI.Label("Range", root)
	rangeLabel.AnchorPoint = Vector2.new(1, 0)
	rangeLabel.Position = UDim2.new(1, 0, 0, 202)
	rangeLabel.Size = UDim2.new(0.5, 0, 0, 18)
	rangeLabel.TextXAlignment = Enum.TextXAlignment.Right
	rangeLabel.TextColor3 = UI.Dark.TextMuted
	rangeLabel.TextSize = 11

	presetScroller = Instance.new("ScrollingFrame")
	presetScroller.Name = "LoadPresets"
	presetScroller.Position = UDim2.fromOffset(0, 226)
	presetScroller.Size = UDim2.new(1, 0, 0, 198)
	presetScroller.BackgroundColor3 = UI.Dark.Backdrop
	presetScroller.BackgroundTransparency = 0.48
	presetScroller.BorderSizePixel = 0
	presetScroller.ScrollBarThickness = 5
	presetScroller.ScrollBarImageColor3 = UI.Dark.TextMuted
	presetScroller.CanvasSize = UDim2.fromOffset(0, 0)
	presetScroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	presetScroller.ScrollingDirection = Enum.ScrollingDirection.Y
	presetScroller.Parent = root
	local scrollerCorner = Instance.new("UICorner")
	scrollerCorner.CornerRadius = UDim.new(0, 8)
	scrollerCorner.Parent = presetScroller

	presetLayout = Instance.new("UIListLayout")
	presetLayout.Padding = UDim.new(0, 6)
	presetLayout.SortOrder = Enum.SortOrder.LayoutOrder
	presetLayout.Parent = presetScroller

	autoButton = makeButton("AutoLoad", "AUTO LOAD", root)
	autoButton.Position = UDim2.fromOffset(0, 434)
	autoButton.Size = UDim2.new(1, 0, 0, 40)

	resetButton = makeButton("Reset", "REMOVE ALL PLATES  •  RETURN TO 0 KG", root)
	resetButton.Position = UDim2.fromOffset(0, 482)
	resetButton.Size = UDim2.new(1, 0, 0, 40)
	resetButton.TextSize = 12

	statusLabel = UI.Label("Status", root)
	statusLabel.Position = UDim2.fromOffset(0, 532)
	statusLabel.Size = UDim2.new(1, 0, 0, 18)
	statusLabel.TextXAlignment = Enum.TextXAlignment.Center
	statusLabel.TextSize = 11
	statusLabel.TextColor3 = UI.Dark.TextMuted

	autoButton.Activated:Connect(function()
		self:_toggleAutoLoad()
	end)
	resetButton.Activated:Connect(function()
		local state: Types.TrainingState = TrainingController:GetState()
		if state.WeightKg > state.MinWeightKg then
			self:_setWeight(state.MinWeightKg)
		end
	end)

	-- Chrome, so dark. The explicit colours above already name UI.Dark; this catches
	-- what the shared helpers painted from the cream default on the way down — the
	-- panel fill, its stroke, and every UI.Label that did not set its own colour.
	UI.ApplyTheme(root, UI.Dark)
	-- Re-asserted after the applicator, which would otherwise restore the theme's
	-- standard panel opacity. This panel is deliberately more solid: it is a dense
	-- list of numbers you read while the world moves behind it.
	root.BackgroundTransparency = 0.03
end

function WeightController:_setWeight(weightKg: number)
	local ok, accepted, message = pcall(function()
		return Net.Function("SetTrainingWeight"):InvokeServer(weightKg)
	end)
	if not ok then
		statusLabel.Text = "Could not reach the weight rack."
		return
	end
	statusLabel.Text = tostring(message or if accepted then "Working weight changed." else "Load refused.")
end

function WeightController:_toggleAutoLoad()
	local state: Types.TrainingState = TrainingController:GetState()
	local requested = not state.AutoLoadEnabled
	local ok, accepted, message = pcall(function()
		return Net.Function("SetAutoLoad"):InvokeServer(requested)
	end)
	if not ok then
		statusLabel.Text = "Could not update Auto Load."
		return
	end
	if accepted ~= true and message == "AUTOLOAD_PASS_REQUIRED" then
		local promptOk, opened, promptMessage = pcall(function()
			return Net.Function("PromptProduct"):InvokeServer("AutoLoad")
		end)
		statusLabel.Text = if promptOk and opened
			then "Complete the Roblox purchase prompt."
			else tostring(promptMessage or "Auto Load is not available yet.")
		return
	end
	statusLabel.Text = tostring(message or "Auto Load updated.")
end

function WeightController:_rebuildPresets(state: Types.TrainingState)
	for _, row in presetRows do
		row.button:Destroy()
	end
	table.clear(presetRows)

	local count = math.floor((state.MaxWeightKg - state.MinWeightKg) / state.StepWeightKg + 0.5)
	for index = 1, count do
		local targetKg = state.MinWeightKg + state.StepWeightKg * index
		local button = makeButton(`Load{index}`, "", presetScroller)
		button.LayoutOrder = index
		button.Size = UDim2.new(1, -8, 0, 46)

		local load = UI.Label("Load", button)
		load.Position = UDim2.fromOffset(14, 0)
		load.Size = UDim2.new(0.46, -14, 1, 0)
		load.Font = UI.Font.Numeric
		load.TextSize = 16
		load.Text = `+{NumberFormat.Format(targetKg)} KG`

		local rowState = UI.Label("State", button)
		rowState.Position = UDim2.fromScale(0.46, 0)
		rowState.Size = UDim2.new(0.54, -14, 1, 0)
		rowState.TextXAlignment = Enum.TextXAlignment.Right
		rowState.Font = UI.Font.Heading
		rowState.TextSize = 11

		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke == nil then
			error("[WeightController] Preset button is missing its stroke")
		end

		-- A Frame is inert by default, so this sits over the whole row without taking
		-- the click it exists to report.
		local flash = Instance.new("Frame")
		flash.Name = "Flash"
		flash.Size = UDim2.fromScale(1, 1)
		flash.BackgroundColor3 = UI.Dark.Text
		flash.BackgroundTransparency = 1
		flash.BorderSizePixel = 0
		flash.ZIndex = button.ZIndex + 1
		flash.Parent = button

		local flashCorner = Instance.new("UICorner")
		flashCorner.CornerRadius = UDim.new(0, 8)
		flashCorner.Parent = flash

		local row: PresetRow = {
			button = button,
			load = load,
			state = rowState,
			stroke = stroke,
			flash = flash,
			targetKg = targetKg,
		}
		table.insert(presetRows, row)

		-- Every row asks, including the ones drawn as locked. The server is the only
		-- thing that actually knows what this player may load, and it answers a refusal
		-- with the stat and number needed, which _setWeight puts on the status line.
		-- Deciding here instead meant a click could land on a panel holding a stale
		-- recommendation and simply vanish — no load, no message, nothing to explain it.
		button.Activated:Connect(function()
			acknowledge(row)

			-- Re-picking the load you already have is the one case with nothing to send:
			-- same weight, and Auto Load already off, so the server would write back what
			-- it holds. With Auto Load on it is a real change -- choosing a load by hand
			-- is what pins it -- so that still goes.
			local live: Types.TrainingState = TrainingController:GetState()
			local same = math.abs(targetKg - live.WeightKg) < 0.001
			if same and not live.AutoLoadEnabled then
				statusLabel.Text = `Already loaded — {NumberFormat.Format(targetKg)} KG.`
				return
			end

			self:_setWeight(targetKg)
		end)
	end

	local currentIndex = math.max(1, math.floor(state.WeightKg / state.StepWeightKg + 0.5))
	task.defer(function()
		if presetScroller.Parent ~= nil then
			presetScroller.CanvasPosition = Vector2.new(0, math.max(0, (currentIndex - 2) * 52))
		end
	end)
end

function WeightController:_render(state: Types.TrainingState)
	local training = state.StationId ~= nil
	root.Visible = training
	if not training or state.StationId == nil then
		lastStationId = nil
		return
	end

	if lastStationId ~= state.StationId then
		statusLabel.Text = ""
		lastStationId = state.StationId
	end

	local rangeKey = `{state.MinWeightKg}:{state.MaxWeightKg}:{state.StepWeightKg}`
	if rangeKey ~= renderedRangeKey then
		renderedRangeKey = rangeKey
		self:_rebuildPresets(state)
	end

	weightLabel.Text = `{NumberFormat.Format(state.WeightKg)} KG`
	meaningLabel.Text = loadMeaning(state.StationId, state.WeightKg)
	rangeLabel.Text = `{NumberFormat.Format(state.StepWeightKg)} KG STEPS`
	local bonusPercent = math.max(0, math.floor((state.WeightMultiplier - 1) * 100 + 0.5))
	bonusLabel.Text = `+{bonusPercent}% STAT GAIN FROM THIS LOAD`

	local definition = EquipmentConfig.Get(state.StationId)
	local statName = if definition ~= nil then definition.StatId else "MUSCLE"
	local tier = if state.ZoneId ~= nil then WeightConfig.Get(state.ZoneId) else nil
	if state.RecommendedWeightKg > state.WeightKg then
		guidanceLabel.Text = `HEAVIER LOAD READY — CHOOSE THE GREEN `
			.. `{NumberFormat.Format(state.RecommendedWeightKg)} KG ROW`
		guidanceLabel.TextColor3 = UI.Dark.Success
	elseif state.WeightKg < state.MaxWeightKg and tier ~= nil then
		local nextWeight = math.min(state.MaxWeightKg, state.WeightKg + state.StepWeightKg)
		local nextRequirement = WeightConfig.RequiredStat(tier, nextWeight)
		guidanceLabel.Text = `NEXT LOAD: {NumberFormat.Format(nextWeight)} KG  •  `
			.. `UNLOCKS AT {NumberFormat.Format(nextRequirement)} {string.upper(statName)}`
		guidanceLabel.TextColor3 = UI.Dark.Power
	elseif state.ZoneId ~= WeightConfig.List[#WeightConfig.List].ZoneId then
		guidanceLabel.Text = "MAX LOAD MASTERED — NEXT AREA READY"
		guidanceLabel.TextColor3 = UI.Dark.Success
	else
		guidanceLabel.Text = "MAXIMUM LOAD MASTERED"
		guidanceLabel.TextColor3 = UI.Dark.Power
	end

	for _, row in presetRows do
		local targetKg = row.targetKg
		local selectable = targetKg <= state.RecommendedWeightKg
		local current = math.abs(targetKg - state.WeightKg) < 0.001
		local recommended = targetKg == state.RecommendedWeightKg and targetKg > state.WeightKg
		-- Every row takes a click, the one you are already on included. Re-picking the
		-- current load is harmless on the server -- it snaps to the same number, pins the
		-- choice by switching Auto Load off, and republishes -- and refusing it only
		-- taught players that the panel ignores them, since from the outside a dead
		-- button and a no-op look identical.
		row.button.Active = true
		row.load.TextColor3 = if selectable then UI.Dark.Text else UI.Dark.TextMuted

		if current then
			row.button.BackgroundColor3 = UI.Dark.Accent
			row.button.BackgroundTransparency = 0.02
			row.state.Text = "CURRENT"
			row.state.TextColor3 = UI.Dark.OnAccent
			row.stroke.Color = UI.Dark.Power
			row.stroke.Transparency = 0.05
		elseif recommended then
			row.button.BackgroundColor3 = UI.Dark.Success
			row.button.BackgroundTransparency = 0.02
			row.state.Text = "RECOMMENDED"
			row.state.TextColor3 = UI.Dark.SuccessInk
			row.stroke.Color = UI.Dark.SuccessEdge
			row.stroke.Transparency = 0.1
		elseif selectable then
			row.button.BackgroundColor3 = UI.Dark.Backdrop
			row.button.BackgroundTransparency = 0.08
			row.state.Text = if targetKg < state.WeightKg then "LIGHTER" else "AVAILABLE"
			row.state.TextColor3 = UI.Dark.TextMuted
			row.stroke.Color = UI.Dark.GlassStroke
			row.stroke.Transparency = 0.55
		else
			local required = if tier ~= nil then WeightConfig.RequiredStat(tier, targetKg) else 0
			row.button.BackgroundColor3 = UI.Dark.Backdrop
			row.button.BackgroundTransparency = 0.5
			row.state.Text = `NEED {NumberFormat.Format(required)} {string.upper(statName)}`
			row.state.TextColor3 = UI.Dark.TextMuted
			row.stroke.Color = UI.Dark.GlassStroke
			row.stroke.Transparency = 0.78
		end
	end

	resetButton.Active = state.WeightKg > state.MinWeightKg
	resetButton.TextTransparency = if resetButton.Active then 0 else 0.58
	resetButton.BackgroundColor3 = if resetButton.Active then UI.Dark.DangerFill else UI.Dark.Backdrop

	if not state.HasAutoLoad then
		autoButton.Text = "BUY AUTO LOAD  •  EQUIPS RECOMMENDED LOADS"
		autoButton.BackgroundColor3 = UI.Dark.Accent:Lerp(UI.Dark.Backdrop, 0.45)
	elseif state.AutoLoadEnabled then
		autoButton.Text = "AUTO LOAD: ON  •  RECOMMENDED LOAD EQUIPPED"
		autoButton.BackgroundColor3 = UI.Dark.Success
	else
		autoButton.Text = "AUTO LOAD: OFF"
		autoButton.BackgroundColor3 = UI.Dark.Backdrop
	end
end

function WeightController:Start()
	self:_build()
	self:_render(TrainingController:GetState())
	TrainingController.Changed:Connect(function(state: Types.TrainingState)
		self:_render(state)
	end)
end

return WeightController
