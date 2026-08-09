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
local MapRender = require(ReplicatedStorage.Modules.MapRender)

-- Punch's cooldown, mirrored for the cooldown sweep. The server remains the
-- authority; this only decides when the pip looks ready.
local PUNCH_COOLDOWN = 0.6
-- A slot is a square big enough to hit with a thumb and small enough that five of
-- them plus their gaps stay narrower than the vitals panel above. Four pixels wider
-- than it was, because a slot now carries a picture of a muscle as well as a number.
local SLOT_SIZE = 48
local SLOT_GAP = 6
-- How much of the slot the muscle glyph takes. The rest is breathing room and the
-- corner where the keybind number sits.
local SLOT_ICON_SCALE = 0.62

-- The minimap, in the corner the eye already goes to for Power and Tokens.
local MINIMAP_WIDTH = 260
local MINIMAP_HEIGHT = 150
-- How many world studs one pixel of the minimap covers. Chosen so the window shows
-- roughly the district around the player: close enough that the streets are streets,
-- wide enough that the next island is on screen before you swim to it.
local MINIMAP_STUDS_PER_PIXEL = 2.6
-- The minimap redraws its offset on a timer rather than every frame. Ten a second is
-- past the point the eye reads it as stepping, and it is a tenth of the work.
local MINIMAP_INTERVAL = 0.1
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

type Slot = { Button: TextButton, Stroke: UIStroke, Number: TextLabel, Icon: Frame }

local slotButtons: { [Types.StatId]: Slot } = {}
-- Which slot is breathing, and how to stop it. Only one stat can be trained at a time,
-- so this is one value rather than one per slot.
local pulsingStat: Types.StatId? = nil
local stopPulse: (() -> ())? = nil
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
local minimapCanvas: Frame? = nil
local minimapProject: ((number, number) -> UDim2)? = nil
local minimapPixels = Vector2.zero
local minimapAt = 0

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

		-- The picture of the muscle, not its name.
		--
		-- Five numbered squares said which slot was selected and nothing about what any
		-- of them trained: a player who had not read the Info screen had no way to know
		-- 3 was Back other than by pressing it and watching a number move. The glyph is
		-- named by the stat's own definition, so a sixth stat brings its own picture and
		-- this loop never learns any stat's name.
		--
		-- Its own holder rather than drawn straight into the button, because the icon is
		-- what pops on selection and breathes while that muscle is being trained, and
		-- UI.Pressable already owns the button's UIScale.
		local iconHolder = Instance.new("Frame")
		iconHolder.Name = "Glyph"
		iconHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		iconHolder.Position = UDim2.fromScale(0.5, 0.46)
		iconHolder.Size = UDim2.fromScale(SLOT_ICON_SCALE, SLOT_ICON_SCALE)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Parent = button
		Icons.Draw(definition.Icon, iconHolder, UI.Palette.TextMuted, UI.Palette.Backdrop)

		-- The keybind, demoted to a corner badge. It is how you press the slot, not
		-- what the slot is, so it no longer gets the whole tile.
		local number = UI.Label("Slot", button)
		number.AnchorPoint = Vector2.new(1, 1)
		number.Position = UDim2.new(1, -4, 1, -1)
		number.Size = UDim2.fromOffset(10, 12)
		number.Font = UI.Font.Numeric
		number.TextSize = 11
		number.TextXAlignment = Enum.TextXAlignment.Right
		number.Text = tostring(index)

		slotButtons[definition.Id] = { Button = button, Stroke = stroke, Number = number, Icon = iconHolder }

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

	-- Under the compact summary: the minimap.
	--
	-- This corner used to be the combat feed — four lines of text that were blank
	-- until somebody hit you, so the most valuable space on the screen spent almost
	-- all of its life as an empty grey box. The hits it reported are better said by
	-- the damage numbers EffectsController already throws up over the crosshair, and
	-- what the corner is actually good for is the question a player in an open world
	-- asks constantly: where am I, and what is near me.
	--
	-- It is also the whole Map button: pressing the picture of the map opens the map.
	self:_buildMinimap(screen)

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
	The corner map, and the way into the full one.

	Drawn from MapRender, the same module the Map screen uses, so the city has one look
	and the server is asked for its shape once no matter which of the two opens first.

	The framing is the part that differs. The Map screen fits the whole world into a
	board and lets you pan it; this keeps the player nailed to the centre of the window
	and slides an oversized canvas underneath them. That is why nothing here rebuilds
	when the player moves — a move is one Position write on a canvas that was drawn once.
]]
function HudController:_buildMinimap(screen: ScreenGui)
	local panel = Instance.new("TextButton")
	panel.Name = "Minimap"
	panel.Position = UDim2.fromOffset(16, 68)
	panel.Size = UDim2.fromOffset(MINIMAP_WIDTH, MINIMAP_HEIGHT)
	panel.BackgroundColor3 = UI.Palette.Glass
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.AutoButtonColor = false
	panel.Text = ""
	panel.ClipsDescendants = true
	panel.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = panel

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI.Palette.GlassStroke
	stroke.Transparency = 0.7
	stroke.Parent = panel

	-- Brighten on hover, so a panel that otherwise looks like a readout admits it is
	-- also a button.
	panel.MouseEnter:Connect(function()
		stroke.Transparency = 0.25
	end)
	panel.MouseLeave:Connect(function()
		stroke.Transparency = 0.7
	end)

	UI.Pressable(panel, { PressScale = 0.985, HoverScale = 1 })
	panel.Activated:Connect(function()
		MenuController:Toggle("Map")
	end)

	local window = Instance.new("Frame")
	window.Name = "Window"
	window.Size = UDim2.fromScale(1, 1)
	window.BackgroundColor3 = MapRender.Paper
	window.BackgroundTransparency = 0.08
	window.BorderSizePixel = 0
	window.ClipsDescendants = true
	window.Parent = panel

	local loading = UI.Label("Loading", window)
	loading.Size = UDim2.fromScale(1, 1)
	loading.TextXAlignment = Enum.TextXAlignment.Center
	loading.TextColor3 = MapRender.Ink
	loading.TextTransparency = 0.4
	loading.Text = "mapping…"

	-- The corner caption, so the panel says what it is and what pressing it does.
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Position = UDim2.fromOffset(6, 6)
	badge.Size = UDim2.fromOffset(60, 20)
	badge.BackgroundColor3 = UI.Palette.Backdrop
	badge.BackgroundTransparency = 0.25
	badge.BorderSizePixel = 0
	badge.ZIndex = 40
	badge.Parent = panel

	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 6)
	badgeCorner.Parent = badge

	local glyph = Instance.new("Frame")
	glyph.Name = "Glyph"
	glyph.AnchorPoint = Vector2.new(0, 0.5)
	glyph.Position = UDim2.new(0, 4, 0.5, 0)
	glyph.Size = UDim2.fromOffset(13, 13)
	glyph.BackgroundTransparency = 1
	glyph.ZIndex = 41
	glyph.Parent = badge
	Icons.Draw("Map", glyph, UI.Palette.Accent, UI.Palette.Backdrop)

	local caption = UI.Label("Caption", badge)
	caption.Position = UDim2.fromOffset(22, 0)
	caption.Size = UDim2.new(1, -24, 1, 0)
	caption.Font = UI.Font.Heading
	caption.TextSize = 11
	caption.TextColor3 = UI.Palette.Accent
	caption.ZIndex = 41
	caption.Text = "MAP"

	-- The player, fixed dead centre: the canvas moves, the dot does not.
	local here = MapRender.Dot(window, "You", 9, UI.Palette.Accent, 30)
	here.Position = UDim2.fromScale(0.5, 0.5)
	here.Visible = false

	-- The fetch is a server round-trip, so it happens off to one side. The panel is a
	-- working button the whole time it is loading.
	task.spawn(function()
		local dests, feats = MapRender.Fetch()
		if #feats == 0 and #dests == 0 then
			loading.Text = "no map data"
			return
		end

		local bounds = MapRender.Bounds(feats, dests)
		local pixels = Vector2.new(
			math.max(bounds.Width / MINIMAP_STUDS_PER_PIXEL, MINIMAP_WIDTH),
			math.max(bounds.Depth / MINIMAP_STUDS_PER_PIXEL, MINIMAP_HEIGHT)
		)

		local canvas = Instance.new("Frame")
		canvas.Name = "Canvas"
		canvas.Size = UDim2.fromOffset(pixels.X, pixels.Y)
		canvas.BackgroundTransparency = 1
		canvas.BorderSizePixel = 0
		canvas.Parent = window

		-- No strokes and no rounded corners down here: both are invisible on a
		-- building three pixels wide, and both cost an instance on a canvas that
		-- holds every building in the city.
		MapRender.DrawFeatures(canvas, feats, bounds, false)

		local project = MapRender.Project(bounds)
		for _, destination in dests do
			local stat = StatConfig.Get(destination.StatId)
			if stat == nil then
				continue
			end
			-- A dot in the muscle's colour and nothing else. The names, the
			-- multipliers and the locks are on the full map, and none of them can be
			-- read at this size anyway.
			local pin = MapRender.Dot(canvas, destination.Id, 6, stat.Color, 20)
			pin.Position = project(destination.Position.X, destination.Position.Z)
		end

		loading:Destroy()
		here.Visible = true
		minimapCanvas = canvas
		minimapProject = project
		minimapPixels = pixels
	end)
end

--[[
	Slides the canvas so the player's projected position sits under the centre dot.
]]
function HudController:_refreshMinimap()
	local canvas = minimapCanvas
	local project = minimapProject
	if canvas == nil or project == nil then
		return
	end

	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end

	-- The projection is in canvas scale, so it is multiplied out by the canvas's own
	-- pixel size rather than by AbsoluteSize: the HUD carries a viewport UIScale, and
	-- reading back a scaled size here would shrink the pan along with it.
	local at = project(root.Position.X, root.Position.Z)
	canvas.Position = UDim2.fromOffset(
		MINIMAP_WIDTH / 2 - at.X.Scale * minimapPixels.X,
		MINIMAP_HEIGHT / 2 - at.Y.Scale * minimapPixels.Y
	)
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
	local changed = selectedStat ~= statId
	selectedStat = statId

	for id, slot in slotButtons do
		local definition = StatConfig.Get(id)
		local chosen = id == statId
		local fill = if chosen
			then (if definition ~= nil then definition.Color else UI.Palette.Accent)
			else UI.Palette.Backdrop
		slot.Button.BackgroundColor3 = fill
		slot.Button.BackgroundTransparency = if chosen then 0.05 else 0.08
		slot.Stroke.Transparency = if chosen then 0 else 1
		slot.Number.TextColor3 = if chosen then UI.Palette.Backdrop else UI.Palette.TextMuted
		-- The glyph inverts on the selected tile: dark on the stat's colour, rather
		-- than a muted grey drawing sitting on a bright red square. `fill` is passed as
		-- the knockout colour for the same reason — a gap punched in the icon has to be
		-- whatever is behind it, and behind it just changed.
		Icons.Recolour(slot.Icon, if chosen then UI.Palette.Backdrop else UI.Palette.TextMuted, fill)
	end

	-- Only on an actual change: Start calls this once to paint the initial state, and a
	-- HUD that pops itself the instant it appears looks like a glitch rather than an
	-- acknowledgement.
	local slot = slotButtons[statId]
	if changed and slot ~= nil then
		UI.Pop(slot.Icon)
	end
end

--[[
	Breathes the slot of the muscle currently being worked.

	The dock says which slot the click trains; this says which one is actually earning
	right now, which during a set is not the same question — a player locked into a
	bench can still switch the click to Legs. Starting and stopping only on a change,
	because the caller runs every frame and a tween restarted 60 times a second is a
	still image.
]]
function HudController:_setPulsing(statId: Types.StatId?)
	if pulsingStat == statId then
		return
	end

	if stopPulse ~= nil then
		stopPulse()
		stopPulse = nil
	end
	pulsingStat = statId

	if statId == nil then
		return
	end
	local slot = slotButtons[statId]
	if slot ~= nil then
		stopPulse = UI.Pulse(slot.Icon)
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

	-- What the left mouse button does right now, which depends on the slot.
	--
	-- There is no [F] any more. Punching was on its own key while the click already
	-- threw a punch whenever Arms was selected, so the game had two answers to "how do
	-- I hit someone" and the prompt only admitted to one of them. Slot 1 is the fist:
	-- select it and the click is a punch, select anything else and the click is reps.
	if selectedStat ~= ARMS_STAT then
		local definition = StatConfig.Get(selectedStat)
		abilityLabel.Text =
			`Click to train {if definition ~= nil then definition.DisplayName else selectedStat}`
		abilityLabel.TextColor3 = if definition ~= nil then definition.Color else UI.Palette.TextMuted
	else
		local remaining = PUNCH_COOLDOWN - (os.clock() - lastPunchAt)
		if remaining > 0 then
			abilityLabel.Text = `Click to punch  —  {string.format("%.1f", remaining)}s`
			abilityLabel.TextColor3 = UI.Palette.TextMuted
		else
			local target = CombatController:FindTarget()
			if target ~= nil then
				abilityLabel.Text = `Click to punch  —  {target.Name}`
				abilityLabel.TextColor3 = UI.Palette.Danger
			else
				abilityLabel.Text = "Click to punch  —  ready"
				abilityLabel.TextColor3 = UI.Palette.Accent
			end
		end
	end

	-- The slot of whatever muscle the machine is working, which is not necessarily the
	-- slot the click is pointed at.
	local trained: Types.StatId? = nil
	if state.StationId ~= nil then
		local definition = EquipmentConfig.Get(state.StationId)
		trained = if definition ~= nil then definition.StatId else nil
	end
	self:_setPulsing(trained)
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

		-- Only the cooldown clock lives here now. What the hit was and what it did for
		-- is EffectsController's damage numbers and ToastController's line, which are
		-- both nearer the middle of the screen than a log in the corner ever was.
		if payload.Kind == "Hit" then
			lastPunchAt = os.clock()
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

		-- The map pans on its own clock. Nothing on it changes between frames except
		-- where the player is standing, and ten updates a second is already smoother
		-- than the eye reads a 260-pixel picture.
		local now = os.clock()
		if now - minimapAt >= MINIMAP_INTERVAL then
			minimapAt = now
			self:_refreshMinimap()
		end
	end)
end

return HudController
