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
local AbilityConfig = require(ReplicatedStorage.Modules.AbilityConfig)
local MapRender = require(ReplicatedStorage.Modules.MapRender)

-- A slot is big enough to hit with a thumb and small enough to sit under the middle
-- of the screen without covering the world.
local SLOT_WIDTH = 66
local SLOT_HEIGHT = 76
local SLOT_GAP = 7

-- The ability bar, bottom-right. Deliberately smaller than the training dock at the
-- bottom centre: the dock is a choice you make between fights and the abilities are
-- reminders of keys you already have your fingers on.
local ABILITY_SLOT = 52
local ABILITY_GAP = 6
-- How much of the slot's width the muscle glyph takes. The rest is the name strip, the
-- keybind corner, and enough margin that the glyph's motion never touches the edge.
local SLOT_ICON_SCALE = 0.68
-- How hard a slot's muscle moves when it is merely idling in the dock, against the 1.0
-- of the muscle actually being worked on a machine. Low: five of these are on screen at
-- once and the row has to read as alive, not as busy.
local SLOT_IDLE_STRENGTH = 0.45
-- Staggered per slot so the five do not breathe in unison, which reads as the whole bar
-- throbbing rather than as five separate muscles.
local SLOT_IDLE_STAGGER = 0.17
-- The minimap, in the corner the eye already goes to for Power and Tokens.
local MINIMAP_WIDTH = 260
local MINIMAP_HEIGHT = 150
-- How many world studs one pixel of the minimap covers. Chosen so the window shows
-- roughly the district around the player: close enough that the streets are streets,
-- wide enough that the next island is on screen before you swim to it.
local MINIMAP_STUDS_PER_PIXEL = 2.6
-- The side of the square of world the minimap draws, in studs. Comfortably more than
-- the window's diagonal (260x150 at 2.6 studs a pixel is about 780 studs corner to
-- corner) so the map never runs out under a rotation, and no larger — see the note on
-- _drawMinimapRegion for why a city-sized canvas was the wrong shape entirely.
local MINIMAP_REGION_STUDS = 1000
-- How far the player may wander from the middle of the drawn square before it is
-- redrawn around them. Well inside the margin the region has over the window.
local MINIMAP_REDRAW_STUDS = 90
-- How far the minimap pulls the world's colours toward white. Much less than the map
-- screen, which is a big board you study; this is a small window you glance at, and it
-- needs the contrast more than it needs the paper look.
local MINIMAP_WASH = 0.2
-- The minimap redraws on a timer rather than every frame. Thirty a second rather than
-- the ten it started at, because the map now turns with the camera and a rotation
-- stepping ten times a second is visibly notchy where a pan is not. The refresh skips
-- its writes entirely when neither the heading nor the position moved enough to see.
local MINIMAP_INTERVAL = 1 / 30
-- How often a held mouse button re-tells the server it is still held. Comfortably
-- inside the server's activity window so holding never flickers off, and slow
-- enough that it costs nothing.
local PING_INTERVAL = 0.4
-- Which stat the fist belongs to. Named rather than inlined so the click handler and
-- anything else that cares cannot quietly disagree about the spelling.
local ARMS_STAT = "Arms"

-- What the dock holds.
--
-- It used to hold all five muscles, and clicking one both selected it and hand-trained
-- it. That made the bottom of the screen a second, worse training interface competing
-- with the machines the whole game is built around — and it buried the one thing the
-- bar needs to be in a fight, which is the fist. So the dock is the fist now.
--
-- The other four are still trained the way the game means them to be: on a machine.
-- Kept as a filtered list rather than a hard-coded single button, because every loop
-- below already reads a list, and a second combat slot should be one entry here.
local DOCK_STATS: { StatConfig.StatDefinition } = {}
for _, definition in StatConfig.List do
	if definition.Id == ARMS_STAT then
		table.insert(DOCK_STATS, definition)
	end
end

-- Where a stat sits in the canonical display order. Shared by the dock and the gain
-- boxes so neither can drift from StatConfig's ordering.
local function statOrder(statId: Types.StatId): number
	for index, definition in StatConfig.List do
		if definition.Id == statId then
			return index
		end
	end
	return #StatConfig.List + 1
end

-- One entry per AbilityConfig row, built once and refreshed on the HUD's render loop.
-- Keyed by ability id rather than held as an array so the refresh never depends on the
-- bar and the config agreeing about order.
type AbilitySlot = {
	Sweep: Frame,
	Key: TextLabel,
	Root: Frame,
}
local abilitySlots: { [string]: AbilitySlot } = {}
local blockMeterFill: Frame? = nil

local DOCK_WIDTH = SLOT_WIDTH * #DOCK_STATS + SLOT_GAP * math.max(0, #DOCK_STATS - 1) + 24
local DOCK_HEIGHT = SLOT_HEIGHT + 20

local HudController = {
	Name = "HudController",
	Priority = 10,
}

local ProfileController: any = nil
local TrainingController: any = nil
local CombatController: any = nil
local MenuController: any = nil
local FullMapController: any = nil

type Slot = {
	Button: TextButton,
	Stroke: UIStroke,
	Gradient: UIGradient,
	Number: TextLabel,
	KeyBadge: Frame,
	Name: TextLabel,
	NameBand: Frame,
	Icon: Frame,
	-- The same glyph Info uses, and its name so motion can start without asking
	-- StatConfig again.
	Glyph: string,
	Order: number,
	-- How hard this slot is currently moving, and how to stop its tween.
	Strength: number?,
	Stop: (() -> ())?,
}

local slotButtons: { [Types.StatId]: Slot } = {}
-- Which muscle the left mouse button trains. Never nil once Start has run: the
-- click has to do something, so there is always a slot selected.
local selectedStat: Types.StatId = DOCK_STATS[1].Id
local clicking = false
-- The input/stat that owns the current manual hold. A dock press must keep training
-- the card that was pressed even if a number key changes the visual selection midway.
local manualInput: InputObject? = nil
local manualStat: Types.StatId? = nil
local powerLabel: TextLabel
local tokenLabel: TextLabel
local fightTokenLabel: TextLabel
local healthBar: UI.Bar
-- The tracker shows the one active step of the quest rotation. Kept as a row count
-- rather than a single hard-coded row because every loop below already reads it, so a
-- second tracked objective would be this number and nothing else.
local GOAL_ROWS = 1
local GOAL_ROW_HEIGHT = 46

type GoalRow = {
	Root: Frame,
	Name: TextLabel,
	Bar: UI.Bar,
}

local goalPanel: Frame
local goalHeading: TextLabel
local goalRows: { GoalRow } = {}
-- The last view the server sent, so a re-render never has to wait for the next quest
-- payout to push a fresh one.
local lastQuestView: { any } = {}
local minimapCanvas: Frame? = nil
local minimapPivot: Frame? = nil
local minimapMarker: Frame? = nil
local minimapLoading: TextLabel? = nil
local minimapProject: ((number, number) -> UDim2)? = nil
-- Where the drawn square is centred, and whether the server has answered yet.
local minimapCentre: Vector3? = nil
local minimapReady = false
local minimapDrawing = false
local minimapAt = 0
--[[
	The bottom-centre gain boxes.

	One box per stat, built once and shown only while that stat is actually earning.
	The old readout was a single card bound to the mounted machine, so hand-training
	produced no feedback at all and a player who had just switched muscles had nothing
	on screen telling them the previous set had landed. A row of boxes says which
	muscles are moving right now and by how much, which is the question the number
	answers.
]]
type GainBox = {
	Root: Frame,
	Icon: Frame,
	Value: TextLabel,
	Gain: TextLabel,
	Caption: TextLabel,
	LastSeenAt: number,
	-- Last reported rate, so the caption can be rebuilt on the ageing sweep without
	-- another payout having to arrive.
	Rate: number,
}

local trainingRow: Frame
local gainBoxes: { [Types.StatId]: GainBox } = {}
local trainingStatId: Types.StatId? = nil
-- How long a box stays up after its last payout. Long enough to survive the gap
-- between reps on a slow machine, short enough that a stat you stopped training
-- clears itself off the bar.
local GAIN_BOX_LIFETIME = 8
-- The bar reads at a glance up to three boxes wide; beyond that it is a list.
local GAIN_BOX_LIMIT = 3
local GAIN_BOX_WIDTH = 168
local GAIN_BOX_HEIGHT = 62

function HudController:Init()
	ProfileController = Loader.Get("ProfileController")
	TrainingController = Loader.Get("TrainingController")
	CombatController = Loader.Get("CombatController")
	MenuController = Loader.Get("MenuController")
	FullMapController = Loader.Get("FullMapController")
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

	-- Top-left: global progression and both currencies. Muscle values live in the five-button
	-- training dock below, where each number is also a direct route to its location.
	--
	-- This was two stacked panels 250px tall. The compact header now leaves the
	-- world visible and the muscle-specific information sits with its action button.
	--
	-- y = 16 is 16 below Roblox's own top bar, not 16 below the screen edge, because
	-- this ScreenGui no longer ignores the inset — see the note where it is built.
	local summary = UI.Panel("Summary", screen)
	summary.Position = UDim2.fromOffset(16, 16)
	summary.Size = UDim2.fromOffset(360, 42)

	UI.VerticalList(summary, 4)

	local headline = Instance.new("Frame")
	headline.Name = "Headline"
	headline.BackgroundTransparency = 1
	headline.Size = UDim2.new(1, 0, 0, 26)
	headline.LayoutOrder = 1
	headline.Parent = summary

	powerLabel = UI.Label("Power", headline)
	powerLabel.Size = UDim2.fromScale(0.42, 1)
	powerLabel.Font = UI.Font.Numeric
	powerLabel.TextSize = 21
	powerLabel.TextColor3 = UI.Palette.Power
	UI.Role(powerLabel, { Ink = "Power" })

	tokenLabel = UI.Label("Tokens", headline)
	tokenLabel.Position = UDim2.fromScale(0.42, 0)
	tokenLabel.Size = UDim2.fromScale(0.3, 1)
	tokenLabel.TextXAlignment = Enum.TextXAlignment.Right
	tokenLabel.Font = UI.Font.Numeric
	tokenLabel.TextSize = 13
	tokenLabel.TextColor3 = UI.Palette.Token
	UI.Role(tokenLabel, { Ink = "Token" })

	-- The dumbbell mark rather than the word "Tokens". The currency is named by its
	-- glyph everywhere it appears — the goal card's reward, the shop's prices, and
	-- here — so the three read as the same thing without spelling it out each time.
	local tokenGlyph = Instance.new("Frame")
	tokenGlyph.Name = "TokenGlyph"
	tokenGlyph.BackgroundTransparency = 1
	tokenGlyph.AnchorPoint = Vector2.new(0, 0.5)
	tokenGlyph.Position = UDim2.fromScale(0.73, 0.5)
	tokenGlyph.Size = UDim2.fromOffset(18, 18)
	tokenGlyph.Parent = headline
	-- Dark chrome, so the glyph's knockout colour — whatever shows through the gaps in
	-- a flat icon — is the dark panel fill, not the cream one.
	Icons.Draw("Token", tokenGlyph, UI.Dark.Token, UI.Dark.Glass)

	fightTokenLabel = UI.Label("FightTokens", headline)
	fightTokenLabel.Position = UDim2.new(0.73, 22, 0, 0)
	fightTokenLabel.Size = UDim2.new(0.27, -22, 1, 0)
	fightTokenLabel.TextXAlignment = Enum.TextXAlignment.Right
	fightTokenLabel.Font = UI.Font.Heading
	fightTokenLabel.TextSize = 13
	fightTokenLabel.TextColor3 = UI.Palette.FightToken
	UI.Role(fightTokenLabel, { Ink = "FightToken" })

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
	chips.Size = UDim2.fromOffset(DOCK_WIDTH, DOCK_HEIGHT)
	chips.BackgroundColor3 = UI.Palette.CartoonInk
	chips.BackgroundTransparency = 0.02

	local dockStroke = chips:FindFirstChildOfClass("UIStroke")
	if dockStroke ~= nil then
		dockStroke.Color = UI.Palette.Border
		dockStroke.Thickness = 3
		dockStroke.Transparency = 0
	end

	self:_buildAbilityBar(screen)

	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(SLOT_WIDTH, SLOT_HEIGHT)
	grid.CellPadding = UDim2.fromOffset(SLOT_GAP, 0)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = chips

	for index, definition in DOCK_STATS do
		local button = Instance.new("TextButton")
		button.Name = definition.Id
		button.LayoutOrder = index
		button.BackgroundColor3 = definition.Color:Lerp(UI.Palette.CartoonInk, 0.72)
		button.BackgroundTransparency = 0
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Text = ""
		button.Parent = chips

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = definition.Color
		stroke.Thickness = 3
		stroke.Transparency = 0.25
		stroke.Parent = button

		local gradient = Instance.new("UIGradient")
		gradient.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, definition.Color:Lerp(UI.Palette.OnAccent, 0.22)),
			ColorSequenceKeypoint.new(0.42, definition.Color:Lerp(UI.Palette.CartoonInk, 0.48)),
			ColorSequenceKeypoint.new(1, definition.Color:Lerp(UI.Palette.CartoonInk, 0.8)),
		})
		gradient.Rotation = 90
		gradient.Parent = button

		local shine = Instance.new("Frame")
		shine.Name = "Shine"
		shine.Size = UDim2.new(1, 0, 0, 3)
		shine.BackgroundColor3 = UI.Palette.OnAccent
		shine.BackgroundTransparency = 0.5
		shine.BorderSizePixel = 0
		shine.ZIndex = 2
		shine.Parent = button

		-- The picture of the muscle, not its name.
		--
		-- Five numbered squares said which slot was selected and nothing about what any
		-- of them trained: a player who had not read the Info screen had no way to know
		-- 3 was Back other than by pressing it and watching a number move. The glyph is
		-- named by the stat's own definition, so a sixth stat brings its own picture and
		-- this loop never learns any stat's name.
		--
		-- Its own holder rather than drawn straight into the button, because the icon is
		-- what pops on selection and what carries the muscle's own motion, and
		-- UI.Pressable already owns the button's UIScale.
		--
		-- Drawn in the stat's own colour. It was drawn in the muted grey the rest of the
		-- HUD uses for secondary text, which on a near-black tile at thirty pixels is a
		-- smudge — the shapes were fine and the contrast was not. Colour also means the
		-- row is legible before any of the five shapes has been learned, because the
		-- stat colours are the game's wayfinding everywhere else.
		local iconHolder = Instance.new("Frame")
		iconHolder.Name = "Glyph"
		iconHolder.AnchorPoint = Vector2.new(0.5, 0.5)
		iconHolder.Position = UDim2.fromScale(0.5, 0.39)
		iconHolder.Size = UDim2.fromScale(SLOT_ICON_SCALE, SLOT_ICON_SCALE)
		iconHolder.BackgroundTransparency = 1
		iconHolder.Parent = button

		-- Match Info exactly. A separate set of 3D figures made the same five stats look
		-- like different concepts in the two places a player sees them most often.
		Icons.Draw(definition.Icon, iconHolder, definition.Color, UI.Palette.Backdrop)

		-- And the word, under the picture.
		--
		-- A drawing of a back and a drawing of a chest are the same rounded blob to
		-- someone who has not been told which is which, however carefully they are
		-- drawn. The picture is what makes a slot findable at a glance once learned; the
		-- name is what teaches it, and four characters of Gotham costs one label.
		local nameBand = Instance.new("Frame")
		nameBand.Name = "NameBand"
		nameBand.AnchorPoint = Vector2.new(0, 1)
		nameBand.Position = UDim2.fromScale(0, 1)
		nameBand.Size = UDim2.new(1, 0, 0, 18)
		nameBand.BackgroundColor3 = UI.Palette.CartoonInk
		nameBand.BackgroundTransparency = 0.18
		nameBand.BorderSizePixel = 0
		nameBand.ZIndex = 2
		nameBand.Parent = button

		local name = UI.Label("Name", nameBand)
		name.AnchorPoint = Vector2.new(0.5, 1)
		name.Position = UDim2.new(0.5, 0, 1, -2)
		name.Size = UDim2.new(1, -4, 0, 14)
		name.Font = UI.Font.Heading
		name.TextSize = 10
		name.TextXAlignment = Enum.TextXAlignment.Center
		name.TextColor3 = UI.Palette.OnAccent
		name.Text = string.upper(definition.DisplayName)
		name.ZIndex = 3

		local numberBadge = Instance.new("Frame")
		numberBadge.Name = "KeyBadge"
		numberBadge.AnchorPoint = Vector2.new(1, 0)
		numberBadge.Position = UDim2.new(1, -4, 0, 4)
		numberBadge.Size = UDim2.fromOffset(18, 18)
		numberBadge.BackgroundColor3 = UI.Palette.CartoonCream
		numberBadge.BorderSizePixel = 0
		numberBadge.ZIndex = 4
		numberBadge.Parent = button

		local badgeAspect = Instance.new("UIAspectRatioConstraint")
		badgeAspect.AspectRatio = 1
		badgeAspect.Parent = numberBadge

		local badgeCorner = Instance.new("UICorner")
		badgeCorner.CornerRadius = UDim.new(1, 0)
		badgeCorner.Parent = numberBadge

		local number = UI.Label("Slot", numberBadge)
		number.Size = UDim2.fromScale(1, 1)
		number.Font = UI.Font.Numeric
		number.TextSize = 10
		number.TextXAlignment = Enum.TextXAlignment.Center
		number.TextColor3 = UI.Palette.CartoonInk
		number.Text = tostring(index)
		number.ZIndex = 5

		slotButtons[definition.Id] = {
			Button = button,
			Stroke = stroke,
			Gradient = gradient,
			Number = number,
			KeyBadge = numberBadge,
			Name = name,
			NameBand = nameBand,
			Icon = iconHolder,
			Glyph = definition.Icon,
			Order = index,
		}

		-- Tapping a slot picks it, the same as pressing its number. It no longer
		-- opens anything: the station list moved to the Map button, because "where
		-- can I train this" is a question about the map.
		UI.Pressable(button, {
			OnPress = function()
				self:_select(definition.Id)
			end,
		})
		-- The five cards are training controls, not merely selectors. Mouse and touch
		-- holds start the same server-authoritative +1/s clock as a world-space click.
		button.InputBegan:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				self:_beginManualTraining(definition.Id, input)
			end
		end)
		button.InputEnded:Connect(function(input: InputObject)
			self:_endManualTraining(input)
		end)
	end

	-- The fist card was the only remaining bottom-centre slot, but world clicks already
	-- punch directly and machines own training. Remove the redundant button and its
	-- panel entirely so combat has an unobstructed centre-bottom view.
	chips:Destroy()
	table.clear(slotButtons)

	self:_buildGainBoxes(screen)

	-- Bottom-left: health, and nothing else.
	--
	-- This was a panel in the middle of the screen carrying the health bar and two lines
	-- of prose — how to mount a machine, and what the left mouse button would do. Both
	-- sentences were permanent: they said the same thing whether or not there was a
	-- machine or an enemy anywhere near, so they stopped being read within a minute of
	-- play and went on occupying the centre of the screen for the rest of the session.
	-- The dock already names the muscle the click trains, and the machines say "Hold E"
	-- on their own signs at the moment it is true.
	--
	-- What is left is the one number that changes while you are being hit, and it goes
	-- in the corner where a health bar belongs.
	healthBar = UI.Bar("Health", UI.Palette.Vital, screen, UI.Palette.Health)
	healthBar.Root.AnchorPoint = Vector2.new(0, 1)
	healthBar.Root.Position = UDim2.new(0, 20, 1, -20)
	healthBar.Root.Size = UDim2.fromOffset(360, 42)
	healthBar.Caption.Font = UI.Font.Numeric
	healthBar.Caption.TextSize = 17
	healthBar.Caption.TextXAlignment = Enum.TextXAlignment.Center

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
	-- useful action never requires opening a menu. This uses the real quest stream.
	goalPanel = UI.Panel("MainGoal", screen)
	goalPanel.AnchorPoint = Vector2.new(1, 0)
	goalPanel.Position = UDim2.new(1, -16, 0, 206)
	-- The heading row, the rows themselves, and the panel's own bottom padding — without
	-- the last term the third bar is clipped off by a few pixels.
	goalPanel.Size = UDim2.fromOffset(260, 30 + GOAL_ROWS * GOAL_ROW_HEIGHT + 16)
	goalPanel.Visible = false

	goalHeading = UI.Label("Heading", goalPanel)
	goalHeading.Size = UDim2.new(1, -76, 0, 18)
	goalHeading.Font = UI.Font.Heading
	goalHeading.TextSize = 13
	goalHeading.TextColor3 = UI.Palette.Token
	UI.Role(goalHeading, { Ink = "Token" })
	goalHeading.Text = "OBJECTIVE"

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
	questButton.TextColor3 = UI.Palette.OnAccent
	-- Fill and ink are separate roles: the chip stays Token in both themes, but the
	-- text on it flips, because OnAccent means "readable against a bright chip".
	UI.Role(questButton, { Ink = "OnAccent", Fill = "Token" })
	questButton.Text = "QUESTS"
	questButton.Parent = goalPanel
	UI.Pressable(questButton)
	questButton.Activated:Connect(function()
		MenuController:Open("Quests")
	end)

	local questCorner = Instance.new("UICorner")
	questCorner.CornerRadius = UDim.new(0, 6)
	questCorner.Parent = questButton

	-- Several objectives, not one.
	--
	-- The card used to pick a single quest by a hard-coded priority table, which meant
	-- adding a quest meant editing that table or being sorted to the back. It also hid
	-- the fact that the muscle dailies are five separate goals: a player training legs
	-- saw an arms goal and concluded the tracker was wrong. Rows are built once and
	-- filled from whatever the server sends.
	for index = 1, GOAL_ROWS do
		local row = Instance.new("Frame")
		row.Name = `Goal{index}`
		row.Position = UDim2.fromOffset(0, 26 + (index - 1) * GOAL_ROW_HEIGHT)
		row.Size = UDim2.new(1, 0, 0, GOAL_ROW_HEIGHT - 6)
		row.BackgroundTransparency = 1
		row.Visible = false
		row.Parent = goalPanel

		local name = UI.Label("Name", row)
		name.Size = UDim2.new(1, 0, 0, 18)
		name.Font = UI.Font.Heading
		name.TextSize = 13
		name.TextColor3 = UI.Palette.Text
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local bar = UI.Bar("Progress", UI.Palette.Token, row)
		bar.Root.Position = UDim2.fromOffset(0, 20)
		bar.Root.Size = UDim2.new(1, 0, 0, 18)

		table.insert(goalRows, { Root = row, Name = name, Bar = bar })
	end

	-- Chrome goes dark; the menu's content panels stay cream. These two sit over the
	-- world permanently, and a bright slab in the corner competes with the game behind
	-- it. The roles the helpers recorded on the way down are what this reads.
	UI.ApplyTheme(summary, UI.Dark)
	UI.ApplyTheme(goalPanel, UI.Dark)
	-- The gain boxes are the same permanent chrome over the world, so they take the same
	-- dark treatment. Left cream, they read as a menu that had opened over the game.
	UI.ApplyTheme(trainingRow, UI.Dark)
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
--[[
	The ability bar: one slot per AbilityConfig row, plus the guard meter under it.

	Built by iterating the config rather than by naming the three abilities, which is
	the point of AbilityConfig existing — a fourth ability appears here without this
	function being opened.

	The cooldown sweep is a frame that fills from the bottom of the slot rather than a
	radial wipe. A radial needs either an image mask or eight rotated frames, and the
	first is an upload; a vertical wipe reads just as clearly at 52 pixels and is one
	Size property.
]]
function HudController:_buildAbilityBar(screen: ScreenGui)
	local entries = AbilityConfig.Ordered()

	local bar = Instance.new("Frame")
	bar.Name = "AbilityBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(1, 1)
	-- Sits directly above the MENU button, whose own footprint is 54 tall at 18 from
	-- the bottom-right (MenuBarController). Stacked rather than placed beside it
	-- because the bar grows with every ability added and the corner does not: the
	-- first layout put them on the same line and the fourth slot went under MENU.
	--
	-- Touch moves MENU up to clear the jump button, so the bar moves with it. Read off
	-- the same condition rather than a second constant, because the two overlapping
	-- again on phones is exactly the bug that would go unnoticed on a desktop test.
	bar.Position = if UserInputService.TouchEnabled
		then UDim2.new(1, -18, 1, -210)
		else UDim2.new(1, -18, 1, -82)
	bar.Size =
		UDim2.fromOffset(ABILITY_SLOT * #entries + ABILITY_GAP * math.max(0, #entries - 1), ABILITY_SLOT + 14)
	bar.Parent = screen

	local row = Instance.new("Frame")
	row.Name = "Slots"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, ABILITY_SLOT)
	row.Parent = bar

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, ABILITY_GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row

	for index, entry in entries do
		local accent = Color3.fromRGB(entry.Color[1], entry.Color[2], entry.Color[3])

		local slot = Instance.new("Frame")
		slot.Name = entry.Id
		slot.LayoutOrder = index
		slot.Size = UDim2.fromOffset(ABILITY_SLOT, ABILITY_SLOT)
		slot.BackgroundColor3 = UI.Palette.CartoonInk
		slot.BackgroundTransparency = 0.08
		slot.BorderSizePixel = 0
		slot.ClipsDescendants = true
		slot.Parent = row

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = slot

		local stroke = Instance.new("UIStroke")
		stroke.Color = accent
		stroke.Thickness = 2
		stroke.Transparency = 0.35
		stroke.Parent = slot

		-- Under the text, over the fill. Grows upward from the bottom as the cooldown
		-- runs, so a slot that is nearly ready looks nearly ready at a glance.
		local sweep = Instance.new("Frame")
		sweep.Name = "Sweep"
		sweep.AnchorPoint = Vector2.new(0, 1)
		sweep.Position = UDim2.fromScale(0, 1)
		sweep.Size = UDim2.fromScale(1, 0)
		sweep.BackgroundColor3 = accent
		sweep.BackgroundTransparency = 0.6
		sweep.BorderSizePixel = 0
		sweep.ZIndex = 2
		sweep.Parent = slot

		local key = UI.Label("Key", slot)
		key.Size = UDim2.new(1, 0, 0, 26)
		key.Position = UDim2.fromOffset(0, 8)
		key.Font = UI.Font.Heading
		key.TextSize = 20
		key.TextColor3 = UI.Palette.OnAccent
		key.TextXAlignment = Enum.TextXAlignment.Center
		key.Text = entry.Glyph
		key.ZIndex = 3

		local name = UI.Label("Name", slot)
		name.Size = UDim2.new(1, -6, 0, 14)
		name.Position = UDim2.new(0, 3, 1, -18)
		name.Font = UI.Font.Body
		name.TextSize = 10
		name.TextColor3 = accent
		name.TextXAlignment = Enum.TextXAlignment.Center
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.Text = string.upper(entry.DisplayName)
		name.ZIndex = 3

		abilitySlots[entry.Id] = { Sweep = sweep, Key = key, Root = slot }
	end

	-- The guard meter, under the whole bar rather than inside the Block slot. It is the
	-- one resource in the game that empties in seconds, and a four-pixel sliver inside a
	-- 52-pixel square is not something anybody reads mid-fight.
	local meterTrack = Instance.new("Frame")
	meterTrack.Name = "BlockMeter"
	meterTrack.AnchorPoint = Vector2.new(1, 1)
	meterTrack.Position = UDim2.fromScale(1, 1)
	meterTrack.Size = UDim2.new(1, 0, 0, 6)
	meterTrack.BackgroundColor3 = UI.Palette.CartoonInk
	meterTrack.BackgroundTransparency = 0.25
	meterTrack.BorderSizePixel = 0
	meterTrack.Parent = bar

	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(0, 3)
	trackCorner.Parent = meterTrack

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(96, 186, 255)
	fill.BorderSizePixel = 0
	fill.Parent = meterTrack

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fill

	blockMeterFill = fill
end

--[[
	Repaints the cooldown sweeps and the guard meter.

	Cooldowns are asked of CombatController rather than tracked here, so the bar can
	never disagree with the controller about whether a press would be accepted — a slot
	that looks ready while the input is being declined reads as the game dropping
	inputs, which is the worst kind of bug because the player blames their connection.
]]
function HudController:_refreshAbilityBar()
	for abilityId, slot in abilitySlots do
		local remaining, total = CombatController:CooldownRemaining(abilityId)
		local ratio = if total > 0 then math.clamp(remaining / total, 0, 1) else 0
		slot.Sweep.Size = UDim2.fromScale(1, ratio)
		slot.Key.TextTransparency = if ratio > 0 then 0.45 else 0
	end

	local fill = blockMeterFill
	if fill == nil then
		return
	end
	local character = Players.LocalPlayer.Character
	local meter = if character ~= nil then character:GetAttribute("BlockMeter") else nil
	local ratio = if type(meter) == "number" then math.clamp(meter, 0, 1) else 1
	fill.Size = UDim2.fromScale(ratio, 1)
	-- Red once the guard is nearly gone. The moment worth knowing about is not "the
	-- meter is draining", it is "this is about to shatter and lock you out".
	fill.BackgroundColor3 = if ratio < 0.25 then UI.Palette.Danger else Color3.fromRGB(96, 186, 255)
end

function HudController:_buildMinimap(screen: ScreenGui)
	local panel = Instance.new("TextButton")
	panel.Name = "Minimap"
	panel.Position = UDim2.fromOffset(16, 68)
	panel.Size = UDim2.fromOffset(MINIMAP_WIDTH, MINIMAP_HEIGHT)
	panel.BackgroundColor3 = UI.Palette.Glass
	-- Opaque, unlike every other HUD panel. The rest of the HUD is glass over the world
	-- because text reads fine with a city faintly behind it; a map does not. A dark roof
	-- passing behind a translucent map is indistinguishable from a feature drawn on it,
	-- and the whole panel reads as two pictures on top of each other.
	panel.BackgroundTransparency = 0
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
		FullMapController:Toggle()
	end)

	-- A CanvasGroup, and it has to be one.
	--
	-- ClipsDescendants does not clip a descendant that is rotated. The map canvas turns
	-- with the camera, so the moment the player looked anywhere but due north the whole
	-- thing — three thousand pixels of land and water, washed most of the way to white —
	-- stopped being clipped by this window and painted itself across the HUD. That was
	-- the white rectangle, and it was also why moving right looked like moving left:
	-- what was on screen was the escaped canvas, not the panel it belongs in.
	--
	-- A CanvasGroup composites its descendants into a texture its own size first, so
	-- anything outside simply is not in the texture. Rotation cannot escape that.
	local window = Instance.new("CanvasGroup")
	window.Name = "Window"
	window.Size = UDim2.fromScale(1, 1)
	-- Dark behind the map, not paper. Anywhere the city has no footprint is open water
	-- or nothing at all, and a pale ground made those gaps indistinguishable from the
	-- features drawn on it.
	window.BackgroundColor3 = UI.Palette.Backdrop
	window.BackgroundTransparency = 0
	window.BorderSizePixel = 0
	window.ClipsDescendants = true
	window.Parent = panel

	local loading = UI.Label("Loading", window)
	loading.Size = UDim2.fromScale(1, 1)
	loading.TextXAlignment = Enum.TextXAlignment.Center
	loading.TextColor3 = UI.Palette.TextMuted
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

	-- The player, fixed dead centre and always pointing up the screen: the map turns,
	-- the marker does not. An arrow rather than a dot, because once the map rotates the
	-- marker is the thing that says which way "up" currently means.
	local here = Instance.new("Frame")
	here.Name = "You"
	here.AnchorPoint = Vector2.new(0.5, 0.5)
	here.Position = UDim2.fromScale(0.5, 0.5)
	here.Size = UDim2.fromOffset(16, 16)
	here.BackgroundTransparency = 1
	here.ZIndex = 30
	here.Visible = false
	here.Parent = window
	Icons.Draw("Arrow", here, UI.Palette.Accent, UI.Palette.Backdrop)

	-- A pivot with no size, sitting exactly where the player marker is. Rotating it
	-- turns the map about the player rather than about the middle of the city, which is
	-- the difference between a minimap and a spinning poster.
	local pivot = Instance.new("Frame")
	pivot.Name = "Pivot"
	pivot.AnchorPoint = Vector2.new(0.5, 0.5)
	pivot.Position = UDim2.fromScale(0.5, 0.5)
	pivot.Size = UDim2.fromOffset(0, 0)
	pivot.BackgroundTransparency = 1
	pivot.Parent = window
	minimapPivot = pivot
	minimapMarker = here
	minimapLoading = loading

	-- The fetch is a server round-trip, so it happens off to one side. The panel is a
	-- working button the whole time it is loading.
	task.spawn(function()
		local dests, feats = MapRender.Fetch()
		if #feats == 0 and #dests == 0 then
			loading.Text = "no map data"
			return
		end
		minimapReady = true
	end)
end

--[[
	Draws the square of city around a point, replacing whatever was drawn before.

	Only the player's own region, not the whole map. The first version drew every feature
	in the city into one canvas 3294 pixels across and slid it under a 260-pixel window,
	which was fine until the canvas started rotating: Roblox does not reliably clip a
	rotated descendant, and an unclipped city-sized canvas is a slab of pale map over the
	whole screen. A region canvas is barely larger than the window, so the worst a
	clipping failure can now do is show a little more map than intended.

	It is also most of the work gone — tens of Frames re-laid-out when the camera turns
	instead of hundreds.
]]
function HudController:_drawMinimapRegion(centre: Vector3)
	local pivot = minimapPivot
	if pivot == nil or not minimapReady or minimapDrawing then
		return
	end

	-- Re-entrancy guard. MapRender.Fetch only yields while the server has not answered,
	-- but if it ever did yield here — a redraw is driven from RenderStepped — two draws
	-- would overlap and leave two canvases stacked on the pivot, which is exactly what a
	-- doubled-up map looks like.
	minimapDrawing = true

	local dests, feats = MapRender.Fetch()
	local bounds = MapRender.BoundsAround(centre.X, centre.Z, MINIMAP_REGION_STUDS / 2)
	local side = MINIMAP_REGION_STUDS / MINIMAP_STUDS_PER_PIXEL

	local canvas = Instance.new("Frame")
	canvas.Name = "Canvas"
	canvas.Size = UDim2.fromOffset(side, side)
	-- Position stays at the pivot's origin forever; panning is done by moving the
	-- canvas's own AnchorPoint to the player's place on it, which puts that place under
	-- the pivot without any arithmetic and keeps it there when the pivot turns.
	canvas.Position = UDim2.fromOffset(0, 0)
	canvas.AnchorPoint = Vector2.new(0.5, 0.5)
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0

	-- No strokes and no rounded corners down here: both are invisible on a building
	-- three pixels wide, and both cost an instance each. The wash comes down hard from
	-- the map screen's: at its 0.62 the water, the land and the paper behind them were
	-- three shades of the same off-white and the panel read as an empty grey box.
	MapRender.DrawFeatures(canvas, MapRender.FeaturesWithin(feats, bounds), bounds, false, MINIMAP_WASH)

	local project = MapRender.Project(bounds)
	for _, destination in dests do
		local stat = StatConfig.Get(destination.StatId)
		if stat == nil then
			continue
		end
		local at = destination.Position
		if
			at.X < bounds.MinX
			or at.X > bounds.MinX + bounds.Width
			or at.Z < bounds.MinZ
			or at.Z > bounds.MinZ + bounds.Depth
		then
			continue
		end
		-- A dot in the muscle's colour and nothing else. The names, the multipliers and
		-- the locks are on the full map, and none of them can be read at this size.
		local pin = MapRender.Dot(canvas, destination.Id, 6, stat.Color, 20)
		pin.Position = project(at.X, at.Z)
	end

	canvas.Parent = pivot

	local previous = minimapCanvas
	minimapCanvas = canvas
	minimapProject = project
	minimapCentre = centre
	if previous ~= nil then
		previous:Destroy()
	end

	if minimapLoading ~= nil then
		minimapLoading:Destroy()
		minimapLoading = nil
	end
	if minimapMarker ~= nil then
		minimapMarker.Visible = true
	end

	-- Belt and braces: any stray canvas from an earlier draw goes, so the pivot holds
	-- exactly one map and a doubled image is impossible by construction.
	for _, child in pivot:GetChildren() do
		if child ~= canvas then
			child:Destroy()
		end
	end

	minimapDrawing = false
end

--[[
	Puts the player's place on the map under the marker, and turns the map so the way
	they are facing is up.

	It used to be north-up and fixed, which is only ever right for a player whose camera
	happens to point at world north: walk south with a north-up map and the marker slides
	*down* the screen while you walk up it. That reads as broken rather than as
	cartographically correct, and it is the one thing a minimap must not do.

	So the map turns instead. `Pivot.Rotation` cancels the camera's heading, which leaves
	the direction the camera faces pointing up the panel, and the arrow can then be drawn
	pointing up and left alone.
]]
function HudController:_refreshMinimap()
	local character = Players.LocalPlayer.Character
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end

	-- Redraw the region when the player nears the edge of the square that was drawn.
	-- The margin is generous, so a walk across the city is a handful of redraws of a few
	-- dozen Frames each rather than anything the player could feel.
	local here = root.Position
	if
		minimapCentre == nil
		or (Vector2.new(here.X, here.Z) - Vector2.new(minimapCentre.X, minimapCentre.Z)).Magnitude
			> MINIMAP_REDRAW_STUDS
	then
		self:_drawMinimapRegion(here)
	end

	local canvas = minimapCanvas
	local pivot = minimapPivot
	local project = minimapProject
	if canvas == nil or pivot == nil or project == nil then
		return
	end

	-- The projection is already in canvas fractions, which is exactly what AnchorPoint
	-- wants — no multiplying by a pixel size, and nothing to go wrong when the HUD's
	-- viewport scale changes the panel's real size underneath us.
	local at = project(here.X, here.Z)
	local anchor = Vector2.new(at.X.Scale, at.Y.Scale)

	local camera = workspace.CurrentCamera
	local rotation = 0
	if camera ~= nil then
		local look = camera.CFrame.LookVector
		-- The canvas puts +X to the right and +Z down, so "up the panel" is -Z. The
		-- camera's heading measured clockwise from there is atan2(X, -Z), and turning
		-- the map by the negative of it leaves whatever the camera faces pointing up.
		rotation = -math.deg(math.atan2(look.X, -look.Z))
	end

	-- Writing these every frame re-lays out every feature on the canvas, so skip the
	-- write when nothing moved enough to see. Standing still costs nothing.
	if math.abs(pivot.Rotation - rotation) > 0.25 then
		pivot.Rotation = rotation
	end
	if (canvas.AnchorPoint - anchor).Magnitude > 0.0002 then
		canvas.AnchorPoint = anchor
	end
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
		local statColor = if definition ~= nil then definition.Color else UI.Palette.Accent
		local fill = if chosen then statColor else statColor:Lerp(UI.Palette.CartoonInk, 0.72)
		slot.Button.BackgroundColor3 = fill
		slot.Button.BackgroundTransparency = 0
		slot.Stroke.Transparency = if chosen then 0 else 0.25
		slot.Gradient.Color = if chosen
			then ColorSequence.new({
				ColorSequenceKeypoint.new(0, statColor:Lerp(UI.Palette.OnAccent, 0.28)),
				ColorSequenceKeypoint.new(1, statColor:Lerp(UI.Palette.CartoonInk, 0.18)),
			})
			else ColorSequence.new({
				ColorSequenceKeypoint.new(0, statColor:Lerp(UI.Palette.CartoonInk, 0.48)),
				ColorSequenceKeypoint.new(1, statColor:Lerp(UI.Palette.CartoonInk, 0.82)),
			})
		slot.KeyBadge.BackgroundColor3 = if chosen then UI.Palette.CartoonInk else UI.Palette.CartoonCream
		slot.Number.TextColor3 = if chosen then statColor else UI.Palette.CartoonInk
		slot.NameBand.BackgroundTransparency = if chosen then 0.08 else 0.18
		slot.Name.TextColor3 = UI.Palette.OnAccent
		-- The picture inverts on the selected tile: dark on the stat's colour, because a
		-- coloured drawing on a tile of its own colour is invisible.
		local ink = if chosen then UI.Palette.OnAccent else statColor
		-- `fill` is the knockout colour for the flat glyph: a gap punched in an icon
		-- has to be whatever is behind it, and behind it just changed.
		Icons.Recolour(slot.Icon, ink, fill)
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
	Sets how hard one slot glyph is moving. Zero stops it. The unchanged-strength guard
	matters because a tween restarted every frame is a still image.
]]
function HudController:_setSlotMotion(statId: Types.StatId, strength: number)
	local slot = slotButtons[statId]
	if slot == nil or slot.Strength == strength then
		return
	end
	slot.Strength = strength

	if slot.Stop ~= nil then
		slot.Stop()
		slot.Stop = nil
	end
	if strength <= 0 then
		return
	end
	-- Staggered by the slot's position in the row, so the five are out of phase.
	slot.Stop = Icons.Animate(slot.Icon, slot.Glyph, strength, (slot.Order - 1) * SLOT_IDLE_STAGGER)
end

--[[
	Decides which of the five symbols are moving and how hard. Standing free, all five
	idle subtly. On a machine, only the stat being earned moves. `trained` is that stat,
	or nil when the player is not mounted.
]]
function HudController:_refreshSlotMotion(trained: Types.StatId?)
	for id in slotButtons do
		local strength = if trained == nil then SLOT_IDLE_STRENGTH elseif id == trained then 1 else 0
		self:_setSlotMotion(id, strength)
	end
end

--[[
	Tells the server the click is happening.

	Deliberately a "still going" ping rather than "grant me a rep": the server owns
	the one-second clock, so spamming the button as fast as possible
	earns exactly the same as holding it. That is the whole reason the client sends
	no amount and the server trusts no number from here.
]]
function HudController:_trainPing()
	Net.Event("ManualTrain"):FireServer(manualStat or selectedStat)
end

function HudController:_beginManualTraining(statId: Types.StatId, input: InputObject)
	if manualInput ~= nil and manualInput ~= input then
		Net.Event("ManualTrain"):FireServer("Stop")
	end
	self:_select(statId)
	manualInput = input
	manualStat = statId
	clicking = true
	Loader.Get("TrainingMuscleHighlightController"):SetLocalStat(statId)
	self:_trainPing()
end

function HudController:_endManualTraining(input: InputObject)
	if manualInput ~= input then
		return
	end
	manualInput = nil
	manualStat = nil
	clicking = false
	Loader.Get("TrainingMuscleHighlightController"):SetLocalStat(nil)
	Net.Event("ManualTrain"):FireServer("Stop")
	-- Clear the gain box on the same frame the button comes up. Waiting for the next
	-- sweep would leave it on screen for up to half a second after you stopped.
	self:_refreshTrainingReadout()
end

-- UI input also reaches UserInputService. Hit-test the dock first so a press on a
-- stat card is not interpreted a second time as a world click (or an Arms punch).
function HudController:_statSlotAt(position: Vector3): Types.StatId?
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil then
		return nil
	end
	for _, object in playerGui:GetGuiObjectsAtPosition(position.X, position.Y) do
		for statId, slot in slotButtons do
			if object == slot.Button or object:IsDescendantOf(slot.Button) then
				return statId
			end
		end
	end
	return nil
end

function HudController:_refreshGoal(view: { any })
	lastQuestView = view

	--[[
		One objective, because the server sends one.

		This used to rank three quests by category and completion share, which was the
		right shape for a log of daily and one-shot quests. The quest system is now a
		single repeating rotation, so the view is a list of exactly one and the ranking
		had nothing left to decide.
	]]
	local quest = view[1]
	if type(quest) ~= "table" or type(quest.Goal) ~= "number" then
		goalPanel.Visible = false
		return
	end

	goalPanel.Visible = true

	local progress = math.max(0, tonumber(quest.Progress) or 0)
	local target = math.max(1, tonumber(quest.Goal) or 1)

	for index, row in goalRows do
		if index > 1 then
			row.Root.Visible = false
			continue
		end
		row.Root.Visible = true
		row.Name.Text = tostring(quest.Description or quest.DisplayName or "Keep training")
		row.Bar.Set(
			math.clamp(progress / target, 0, 1),
			`{NumberFormat.Format(progress)} / {NumberFormat.Format(target)}  ·  +{NumberFormat.Format(
				tonumber(quest.TokenReward) or 0
			)}`
		)
	end

	-- The rotation number is the only sense of long-term progress the cycle gives, so
	-- it goes in the heading rather than being invisible.
	local loop = tonumber(quest.Loop)
	goalHeading.Text = if loop ~= nil then `OBJECTIVE · ROTATION {loop}` else "OBJECTIVE"
end

function HudController:_refreshProfile()
	local data = ProfileController:Get()
	if data == nil then
		return
	end

	powerLabel.Text = `POWER  {NumberFormat.FormatGain(Formulas.TotalPower(data.Stats))}`
	tokenLabel.Text = `TOKENS  {NumberFormat.Format(data.Tokens)}`
	fightTokenLabel.Text = `FIGHT  {NumberFormat.Format(data.FightTokens)}`
	self:_refreshTrainingReadout()
end

--[[
	Every stat gets a box up front, hidden. Building them lazily on the first payout
	would put five icon draws inside the rep that lands them, which is exactly the
	frame that must not hitch.
]]
function HudController:_buildGainBoxes(screen: ScreenGui)
	trainingRow = Instance.new("Frame")
	trainingRow.Name = "TrainingGainRow"
	trainingRow.AnchorPoint = Vector2.new(0.5, 1)
	trainingRow.Position = UDim2.new(0.5, 0, 1, -116)
	trainingRow.Size =
		UDim2.fromOffset(GAIN_BOX_WIDTH * GAIN_BOX_LIMIT + SLOT_GAP * (GAIN_BOX_LIMIT - 1), GAIN_BOX_HEIGHT)
	trainingRow.BackgroundTransparency = 1
	trainingRow.Parent = screen

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, SLOT_GAP)
	layout.Parent = trainingRow

	for _, definition in StatConfig.List do
		local root = UI.Panel(`Gain{definition.Id}`, trainingRow)
		root.Size = UDim2.fromOffset(GAIN_BOX_WIDTH, GAIN_BOX_HEIGHT)
		root.BackgroundColor3 = UI.Palette.Backdrop
		root.BackgroundTransparency = 0.06
		root.Visible = false

		local stroke = Instance.new("UIStroke")
		stroke.Color = definition.Color
		stroke.Thickness = 2
		stroke.Transparency = 0.25
		stroke.Parent = root

		local icon = Instance.new("Frame")
		icon.Name = "StatIcon"
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.new(0, 10, 0.5, 0)
		icon.Size = UDim2.fromOffset(38, 38)
		icon.BackgroundTransparency = 1
		icon.Parent = root
		Icons.Draw(definition.Icon, icon, definition.Color, UI.Palette.Backdrop)

		local value = UI.Label("Value", root)
		value.Position = UDim2.fromOffset(56, 6)
		value.Size = UDim2.new(1, -66, 0, 26)
		value.Font = UI.Font.Numeric
		value.TextSize = 20
		value.TextColor3 = UI.Palette.Text

		local gain = UI.Label("Gain", root)
		gain.Position = UDim2.fromOffset(56, 31)
		gain.Size = UDim2.new(1, -66, 0, 18)
		gain.Font = UI.Font.Numeric
		gain.TextSize = 15
		gain.TextColor3 = definition.Color

		local caption = UI.Label("Caption", root)
		caption.Position = UDim2.fromOffset(56, 46)
		caption.Size = UDim2.new(1, -66, 0, 13)
		caption.Font = UI.Font.Heading
		caption.TextSize = 10
		caption.TextColor3 = UI.Palette.TextMuted
		caption.Text = ""

		gainBoxes[definition.Id] = {
			Root = root,
			Icon = icon,
			Value = value,
			Gain = gain,
			Caption = caption,
			LastSeenAt = 0,
			Rate = 0,
		}
	end
end

--[[
	One landed payout. Called for machine reps and hand-training alike — the server
	sends the same payload for both, and the bar deliberately does not distinguish
	them: a stat went up, and this is by how much.
]]
function HudController:_pushGain(statId: Types.StatId, amount: number, perSecond: number)
	local box = gainBoxes[statId]
	if box == nil then
		return
	end

	box.LastSeenAt = os.clock()
	-- The payout is the headline; the rate goes on the caption line, which is the only
	-- way both fit inside a box narrow enough to sit three abreast.
	box.Gain.Text = `+{NumberFormat.FormatGain(amount)}`
	box.Rate = perSecond
	if not box.Root.Visible then
		box.Root.Visible = true
	end
	UI.Pop(box.Root, 0.06)
	self:_refreshTrainingReadout()
end

--[[
	Shows a box per stat currently earning, and refreshes the totals from the replicated
	profile so the big number is the authoritative one rather than a client-side sum.

	The boxes belong to the act of training, not to the last payout. They used to age
	out on a timer, which meant letting go of a machine left the number sitting there
	for another eight seconds claiming you were still earning. Stopping now clears them
	on the same frame, and the timer survives only as a backstop for a stat that stops
	paying while you are still training something else.
]]
function HudController:_refreshTrainingReadout()
	local state = TrainingController:GetState()
	local station = if state.StationId ~= nil then EquipmentConfig.Get(state.StationId) else nil
	trainingStatId = if station ~= nil then station.StatId else nil

	local data = ProfileController:Get()
	local now = os.clock()

	-- Mounted on a machine, or holding the manual train button. Either counts; nothing
	-- else does.
	local isTraining = trainingStatId ~= nil or manualStat ~= nil
	if not isTraining then
		for _, box in gainBoxes do
			box.Root.Visible = false
			box.LastSeenAt = 0
		end
		return
	end

	-- Newest first, so the limit drops the stalest box rather than an arbitrary one.
	local live: { Types.StatId } = {}
	for statId, box in gainBoxes do
		if now - box.LastSeenAt <= GAIN_BOX_LIFETIME and box.LastSeenAt > 0 then
			table.insert(live, statId)
		else
			box.Root.Visible = false
		end
	end
	table.sort(live, function(a, b)
		return gainBoxes[a].LastSeenAt > gainBoxes[b].LastSeenAt
	end)

	for rank, statId in live do
		local box = gainBoxes[statId]
		if rank > GAIN_BOX_LIMIT then
			box.Root.Visible = false
			continue
		end

		box.Root.Visible = true
		-- Recency decides which boxes survive the limit, but never where they sit:
		-- laying them out newest-first made three muscles training at once swap places
		-- on every rep, so the number you were reading moved out from under your eye.
		-- StatConfig order is fixed, so a box appears and disappears but never jumps.
		box.Root.LayoutOrder = statOrder(statId)
		box.Value.Text = if data ~= nil then NumberFormat.Format(data.Stats[statId] or 0) else "—"

		local rate = `{NumberFormat.FormatGain(box.Rate)}/SEC`
		box.Caption.Text = if statId == trainingStatId and station ~= nil
			then `{rate} · {string.upper(station.DisplayName)}`
			else rate
	end

	-- Mounted but nothing has paid out yet: say so rather than showing nothing, since
	-- the first rep on a slow machine is several seconds away.
	if trainingStatId ~= nil then
		local box = gainBoxes[trainingStatId]
		if box ~= nil and not box.Root.Visible then
			box.Root.Visible = true
			box.Root.LayoutOrder = 0
			box.Value.Text = if data ~= nil
				then NumberFormat.Format(data.Stats[trainingStatId] or 0)
				else "—"
			box.Gain.Text = "BUILDING REP…"
			box.Caption.Text = if station ~= nil then string.upper(station.DisplayName) else ""
		end
	end
end

function HudController:_refreshVitals()
	local state = TrainingController:GetState()

	local character = Players.LocalPlayer.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil

	if humanoid ~= nil and humanoid.MaxHealth > 0 then
		healthBar.Set(
			humanoid.Health / humanoid.MaxHealth,
			`HEALTH  {NumberFormat.Format(math.max(0, humanoid.Health))} / {NumberFormat.Format(
				humanoid.MaxHealth
			)}`
		)
	else
		healthBar.Set(0, "HEALTH  —")
	end

	-- The slot of whatever muscle the machine is working, which is not necessarily the
	-- slot the click is pointed at.
	local trained: Types.StatId? = nil
	if state.StationId ~= nil then
		local definition = EquipmentConfig.Get(state.StationId)
		trained = if definition ~= nil then definition.StatId else nil
	end
	self:_refreshSlotMotion(trained)
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

	Net.Event("TrainingGain").OnClientEvent:Connect(function(payload: any)
		if
			type(payload) == "table"
			and type(payload.StatId) == "string"
			and type(payload.Amount) == "number"
			and type(payload.PerSecond) == "number"
		then
			-- No filter on the mounted stat: hand-training and a machine both land here,
			-- and both deserve a box.
			self:_pushGain(payload.StatId, math.max(0, payload.Amount), math.max(0, payload.PerSecond))
		end
	end)

	-- Boxes age out on their own, so a stat that stops earning clears without needing
	-- another payout to trigger the sweep.
	task.spawn(function()
		while true do
			task.wait(0.5)
			self:_refreshTrainingReadout()
		end
	end)

	TrainingController.Changed:Connect(function()
		self:_refreshTrainingReadout()
		-- Mounting changes which objective is most relevant, so re-rank the tracker.
		self:_refreshGoal(lastQuestView)
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

		for index, definition in DOCK_STATS do
			if DIGITS[index] ~= nil and input.KeyCode == DIGITS[index] then
				self:_select(definition.Id)
				return
			end
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if self:_statSlotAt(input.Position) ~= nil then
				return
			end
			-- A click in the world throws a punch, and only a punch.
			--
			-- It used to start the manual-training clock as well, which paid one Arms
			-- a second for holding the button — so fighting was also the fastest way
			-- to train the stat that makes you hit harder, anywhere, with no machine
			-- and no travel. Punching now pays only what a landed hit is worth
			-- (Punch.ARMS_PER_HIT), and training is the dock card and the machines.
			CombatController:Attack()
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:_endManualTraining(input)
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
		self:_refreshAbilityBar()

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
