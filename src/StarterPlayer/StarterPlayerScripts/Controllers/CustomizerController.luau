--!strict
--[[
	CustomizerController — the character creator.

	It opens by itself the first time a player ever joins, because a game where
	everyone is the same untextured bruiser needs the moment where you become *your*
	bruiser to happen before the grind starts, not three menus deep after it. After
	that it is a row in Settings.

	The panel is a preview, not a transaction. Every swatch and every stepper repaints
	the live character immediately and saves nothing; Apply sends the whole look in
	one call. That is why the choice can be abandoned by closing the panel — the
	server's attributes are still the ones it stamped, so the next redraw undoes
	anything uncommitted.

	The first-join pass is **not** enforced from here. The lock that holds a player
	still is the Customizing attribute AppearanceService writes, and Apply clears it
	by saving; a client that skipped this panel entirely would simply be a client that
	cannot walk. Hiding the close button is a courtesy to the player, not the rule.

	The columns are built by walking the config arrays, so a new skin tone or hairstyle
	appears here without this file changing.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AppearanceConfig = require(ReplicatedStorage.Modules.AppearanceConfig)
local FaceConfig = require(ReplicatedStorage.Modules.FaceConfig)
local HairConfig = require(ReplicatedStorage.Modules.HairConfig)
local Icons = require(ReplicatedStorage.Modules.Icons)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local Net = require(ReplicatedStorage.Modules.Net)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local UI = require(ReplicatedStorage.Modules.UI)

local CustomizerController = {
	Name = "CustomizerController",
	-- After AppearanceController (45), whose Preview it drives.
	Priority = 47,
}

local PANEL_SIZE = Vector2.new(380, 470)
local ROW_HEIGHT = 46
local SWATCH_SIZE = 30

-- How far the panel slides in from, and how long each row waits behind the one above
-- it. The stagger is the whole entrance: six rows arriving together is a pop-up, six
-- rows arriving in sequence is a deal being laid out.
local SLIDE_FROM = 90
local ROW_STAGGER = 0.045

local player = Players.LocalPlayer

local AppearanceController: any = nil
local CustomizerStageController: any = nil
local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local panelFrame: Frame
local rows: Frame
local applyButton: TextButton
local closeButton: TextButton
local titleLabel: TextLabel
local rankLabel: TextLabel
local nameLabel: TextLabel
local powerLabel: TextLabel

local isOpen = false
local choice = {
	SkinId = "Tan",
	PantId = "Charcoal",
	HairId = "Buzz",
	FaceId = "Neutral",
}

local function currentCharacter(): Model?
	local character = player.Character
	if character ~= nil and character:FindFirstChild("Head") ~= nil then
		return character
	end
	return nil
end

--[[
	Repaints the live body from the working choice.

	Skin and shorts are written straight onto the character's BodyColors: the server
	owns that instance, but a client-side write is local-only and the server repaints
	it on the next Refresh, which is exactly the preview semantics wanted here.
]]
local function preview()
	local character = currentCharacter()
	if character == nil then
		return
	end

	local body = character:FindFirstChildOfClass("BodyColors")
	if body ~= nil then
		local skin = AppearanceConfig.Color(AppearanceConfig.SkinTones, choice.SkinId)
		local pants = AppearanceConfig.Color(AppearanceConfig.PantColors, choice.PantId)
		body.HeadColor3 = skin
		body.TorsoColor3 = skin
		body.LeftArmColor3 = skin
		body.RightArmColor3 = skin
		body.LeftLegColor3 = pants
		body.RightLegColor3 = pants
		for _, name in { "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot" } do
			local part = character:FindFirstChild(name)
			if part ~= nil and part:IsA("BasePart") then
				part.Color = skin
			end
		end
	end

	AppearanceController:Preview(character, choice.HairId, choice.FaceId)
end

-- One labelled line in the left column. Everything in the panel is one of these.
local function row(order: number, title: string): Frame
	local line = Instance.new("Frame")
	line.Name = title
	line.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	line.BackgroundColor3 = UI.Palette.SurfaceRaised
	line.BackgroundTransparency = 0.25
	line.BorderSizePixel = 0
	line.LayoutOrder = order
	UI.Role(line, { Ink = "SurfaceRaised" })
	line.Parent = rows

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = line

	local label = UI.Label("Title", line)
	label.Position = UDim2.fromOffset(12, 0)
	label.Size = UDim2.new(0, 74, 1, 0)
	label.Font = UI.Font.Heading
	label.TextSize = 13
	label.Text = title

	return line
end

local function heading(order: number, text: string)
	local label = UI.Label("Heading", rows)
	label.Size = UDim2.new(1, 0, 0, 30)
	label.LayoutOrder = order
	label.Font = UI.Font.Heading
	label.TextSize = 15
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextColor3 = UI.Palette.Accent
	UI.Role(label, { Ink = "Accent" })
	label.Text = text
end

--[[
	A strip of colour swatches. The whole palette is on screen at once rather than
	behind a stepper: colour is the one choice a player can judge instantly, and
	clicking through eight tones to compare two of them is the slowest way to make
	the easiest decision here.
]]
local function swatchRow(order: number, title: string, list: { AppearanceConfig.Swatch }, field: string)
	local line = row(order, title)
	local marks: { [string]: UIStroke } = {}

	local strip = Instance.new("Frame")
	strip.Name = "Swatches"
	strip.Position = UDim2.fromOffset(92, 0)
	strip.Size = UDim2.new(1, -104, 1, 0)
	strip.BackgroundTransparency = 1
	strip.Parent = line

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 5)
	layout.Parent = strip

	local function mark()
		for id, stroke in marks do
			local selected = (choice :: any)[field] == id
			stroke.Color = if selected then UI.Palette.Accent else UI.Palette.Border
			stroke.Transparency = if selected then 0 else 0.55
			stroke.Thickness = if selected then 3 else 1
		end
	end

	for index, swatch in list do
		local button = Instance.new("TextButton")
		button.Name = swatch.Id
		button.LayoutOrder = index
		button.Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE)
		button.BackgroundColor3 = Color3.fromRGB(swatch.R, swatch.G, swatch.B)
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Text = ""
		button.Parent = strip

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Color = UI.Palette.Border
		stroke.Transparency = 0.55
		stroke.Parent = button
		marks[swatch.Id] = stroke

		UI.Pressable(button, {
			PressScale = 0.9,
			HoverScale = 1.08,
		})

		button.Activated:Connect(function()
			(choice :: any)[field] = swatch.Id
			mark()
			preview()
		end)
	end

	mark()
end

--[[
	A named choice with arrows either side. Styles need their name shown — a
	silhouette of a mohawk in a 30-pixel square is not a choice anyone can read — so
	these step rather than displaying every option at once.
]]
local function stepperRow(order: number, title: string, ids: { string }, names: { string }, field: string)
	local line = row(order, title)

	local display = UI.Label("Value", line)
	display.AnchorPoint = Vector2.new(0.5, 0.5)
	display.Position = UDim2.fromScale(0.62, 0.5)
	display.Size = UDim2.fromOffset(128, 30)
	display.Font = UI.Font.Heading
	display.TextSize = 13
	display.TextXAlignment = Enum.TextXAlignment.Center

	local function indexOf(): number
		for index, id in ids do
			if (choice :: any)[field] == id then
				return index
			end
		end
		return 1
	end

	local function show()
		display.Text = names[indexOf()]
	end

	local function arrow(name: string, glyph: string, anchorX: number, positionX: number, step: number)
		local button = Instance.new("TextButton")
		button.Name = name
		button.AnchorPoint = Vector2.new(anchorX, 0.5)
		button.Position = UDim2.new(positionX, if step < 0 then 92 else -12, 0.5, 0)
		button.Size = UDim2.fromOffset(30, 30)
		button.BackgroundColor3 = UI.Palette.Backdrop
		button.BackgroundTransparency = 0.2
		button.BorderSizePixel = 0
		button.AutoButtonColor = false
		button.Font = UI.Font.Heading
		button.TextSize = 15
		button.TextColor3 = UI.Palette.Text
		button.Text = glyph
		UI.Role(button, { Ink = "Text", Fill = "Backdrop" })
		button.Parent = line

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 6)
		corner.Parent = button

		UI.Pressable(button, {
			PressScale = 0.9,
		})

		button.Activated:Connect(function()
			-- Wrap rather than clamp: the lists are short enough that stopping at the
			-- end just reads as a dead button.
			local next = ((indexOf() - 1 + step) % #ids) + 1
			(choice :: any)[field] = ids[next]
			show()
			preview()
		end)
	end

	arrow("Previous", "‹", 0, 0, -1)
	arrow("Next", "›", 1, 1, 1)
	show()
end

function CustomizerController:_build()
	local playerGui = player:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymCustomizer"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = false
	screen.DisplayOrder = 7
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screen.Enabled = false
	screen.Parent = playerGui
	UI.ScaleWithViewport(screen)

	-- No scrim. The whole point of this page is looking at the character behind it,
	-- so the world stays bright and the panel stays out of the middle of the screen.
	local panel = UI.Panel("Customizer", screen)
	panelFrame = panel
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 34, 0.5, 0)
	panel.Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y)
	panel.BackgroundTransparency = 0.06
	panel.Active = true

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = PANEL_SIZE.X / PANEL_SIZE.Y
	aspect.Parent = panel

	--[[
		The name block, centred over the figure like a fighter select.

		It is deliberately not inside the panel: the panel is controls, and this is the
		player. Putting a rank the size of a headline over the body is the cheapest way
		to make a menu feel like it is about someone.
	]]
	local header = Instance.new("Frame")
	header.Name = "Header"
	header.AnchorPoint = Vector2.new(0.5, 0)
	header.Position = UDim2.fromScale(0.5, 0.06)
	header.Size = UDim2.fromOffset(520, 116)
	header.BackgroundTransparency = 1
	header.Parent = screen

	rankLabel = UI.Label("Rank", header)
	rankLabel.Size = UDim2.new(1, 0, 0, 28)
	rankLabel.Font = UI.Font.Heading
	rankLabel.TextSize = 22
	rankLabel.TextXAlignment = Enum.TextXAlignment.Center
	rankLabel.Text = ""

	nameLabel = UI.Label("Name", header)
	nameLabel.Position = UDim2.fromOffset(0, 26)
	nameLabel.Size = UDim2.new(1, 0, 0, 54)
	nameLabel.Font = UI.Font.Heading
	nameLabel.TextSize = 44
	nameLabel.TextXAlignment = Enum.TextXAlignment.Center
	nameLabel.TextColor3 = UI.Dark.Text
	nameLabel.Text = player.DisplayName

	powerLabel = UI.Label("Power", header)
	powerLabel.Position = UDim2.fromOffset(0, 82)
	powerLabel.Size = UDim2.new(1, 0, 0, 22)
	powerLabel.Font = UI.Font.Heading
	powerLabel.TextSize = 14
	powerLabel.TextXAlignment = Enum.TextXAlignment.Center
	powerLabel.TextColor3 = UI.Dark.TextMuted
	powerLabel.Text = ""

	titleLabel = UI.Label("Title", panel)
	titleLabel.Size = UDim2.new(1, -44, 0, 34)
	titleLabel.Font = UI.Font.Heading
	titleLabel.TextSize = 18
	titleLabel.Text = "APPEARANCE"

	closeButton = Icons.CloseButton(panel, {
		Size = 32,
		OnActivated = function()
			self:Close()
		end,
	})
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)

	rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromOffset(0, 38)
	rows.Size = UDim2.new(1, 0, 1, -96)
	rows.BackgroundTransparency = 1
	rows.Parent = panel
	UI.VerticalList(rows, 8)

	local randomButton = Instance.new("TextButton")
	randomButton.Name = "Randomize"
	randomButton.AnchorPoint = Vector2.new(0, 1)
	randomButton.Position = UDim2.fromScale(0, 1)
	randomButton.Size = UDim2.fromOffset(104, 46)
	randomButton.BackgroundColor3 = UI.Palette.SurfaceRaised
	randomButton.BackgroundTransparency = 0.1
	randomButton.BorderSizePixel = 0
	randomButton.AutoButtonColor = false
	randomButton.Font = UI.Font.Heading
	randomButton.TextSize = 14
	randomButton.TextColor3 = UI.Palette.Text
	randomButton.Text = "RANDOM"
	UI.Role(randomButton, { Ink = "Text", Fill = "SurfaceRaised" })
	randomButton.Parent = panel

	local randomCorner = Instance.new("UICorner")
	randomCorner.CornerRadius = UDim.new(0, 9)
	randomCorner.Parent = randomButton

	UI.Pressable(randomButton, {
		PressScale = 0.95,
	})

	randomButton.Activated:Connect(function()
		self:_randomize()
	end)

	applyButton = Instance.new("TextButton")
	applyButton.Name = "Apply"
	applyButton.AnchorPoint = Vector2.new(1, 1)
	applyButton.Position = UDim2.fromScale(1, 1)
	applyButton.Size = UDim2.new(1, -112, 0, 46)
	applyButton.BackgroundColor3 = UI.Palette.Success
	applyButton.BorderSizePixel = 0
	applyButton.AutoButtonColor = false
	applyButton.Font = UI.Font.Heading
	applyButton.TextSize = 17
	applyButton.TextColor3 = UI.Palette.SuccessInk
	applyButton.Text = "APPLY"
	UI.Role(applyButton, { Ink = "SuccessInk", Fill = "Success" })
	applyButton.Parent = panel

	local applyCorner = Instance.new("UICorner")
	applyCorner.CornerRadius = UDim.new(0, 9)
	applyCorner.Parent = applyButton

	UI.Pressable(applyButton, {
		PressScale = 0.97,
	})

	applyButton.Activated:Connect(function()
		self:_apply()
	end)

	-- The panel floats over the world rather than inside a menu page, so it takes the
	-- dark chrome the HUD uses instead of the cream menu paper.
	UI.ApplyTheme(screen, UI.Dark)
	-- The rank colour is set per player and must survive the theme pass.
	self:_refreshHeader()
end

--[[
	Fills the name block from the profile. Rank supplies both the word and the colour,
	so a Titan's screen is lit and titled in the same orange as their nameplate.
]]
function CustomizerController:_refreshHeader()
	local data = ProfileController:Get()
	local selected = if data ~= nil then RankConfig.GetById(data.SelectedTitleId) else nil
	-- A title that no longer exists in the config falls back to the first rank rather
	-- than leaving the headline blank.
	local rank = selected or RankConfig.List[1]

	rankLabel.Text = string.upper(rank.DisplayName)
	rankLabel.TextColor3 = rank.Color
	nameLabel.Text = player.DisplayName

	local power = if data ~= nil then Formulas.TotalPower(data.Stats) else 0
	powerLabel.Text = `{NumberFormat.Format(power)} POWER`
end

--[[
	Slides the panel in and deals the rows out one after another.

	The rows are tweened from their own laid-out position rather than animated by the
	layout, because a UIListLayout owns Position: anything this function wrote there
	would be overwritten the moment the layout next ran. Offsetting a UIScale and a
	transparency leaves the layout alone.
]]
function CustomizerController:_playEntrance()
	panelFrame.Position = UDim2.new(0, 34 - SLIDE_FROM, 0.5, 0)
	panelFrame.BackgroundTransparency = 1

	local slide = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(panelFrame, slide, {
		Position = UDim2.new(0, 34, 0.5, 0),
		BackgroundTransparency = 0.06,
	}):Play()

	local index = 0
	for _, child in rows:GetChildren() do
		if not child:IsA("GuiObject") then
			continue
		end
		index += 1

		local scale = child:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Scale = 0.86
		scale.Parent = child

		local wasTransparent = child.BackgroundTransparency
		child.BackgroundTransparency = 1

		task.delay(index * ROW_STAGGER, function()
			if child.Parent == nil then
				return
			end
			local step = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			TweenService:Create(scale, step, { Scale = 1 }):Play()
			TweenService:Create(child, TweenInfo.new(0.28), { BackgroundTransparency = wasTransparent })
				:Play()
		end)
	end
end

function CustomizerController:_apply()
	local saving = applyButton.Text
	applyButton.Text = "SAVING…"

	local ok, message = Net.Function("SetAppearance"):InvokeServer({
		SkinId = choice.SkinId,
		PantId = choice.PantId,
		HairId = choice.HairId,
		FaceId = choice.FaceId,
	})

	applyButton.Text = saving
	if not ok then
		ToastController:Show(message, UI.Palette.Danger)
		return
	end

	-- No sound here. This used to play RankUp — a metal hit with a 2.4 second reverb
	-- tail — at the exact moment the music and ambience fade in behind the curtain,
	-- and three loud things at once is what a player hears as one loud thing. The
	-- curtain wipe and the toast are the confirmation.
	-- The stage comes down behind black. Dropping the lights and the letterbox in
	-- plain sight is the one moment that would give away that this was a menu.
	CustomizerStageController:Curtain(function()
		self:Close()
	end)
	ToastController:Show(message, UI.Palette.Vital)
end

--[[
	Rolls a whole look at once.

	It rolls every field rather than one at a time because the button is for players
	who do not want to make four decisions, and handing them a random hairstyle on
	their own careful colours is neither their look nor a random one.
]]
function CustomizerController:_randomize()
	choice.SkinId = AppearanceConfig.SkinTones[math.random(#AppearanceConfig.SkinTones)].Id
	choice.PantId = AppearanceConfig.PantColors[math.random(#AppearanceConfig.PantColors)].Id
	choice.HairId = HairConfig.Styles[math.random(#HairConfig.Styles)].Id
	choice.FaceId = FaceConfig.Faces[math.random(#FaceConfig.Faces)].Id

	self:_rebuild()
	preview()
end

function CustomizerController:IsOpen(): boolean
	return isOpen
end

function CustomizerController:Open(isFirstTime: boolean)
	local MenuController = Loader.Get("MenuController")
	if MenuController:GetOpenTab() ~= nil then
		MenuController:Toggle()
	end
	local FullMapController = Loader.Get("FullMapController")
	if FullMapController:IsOpen() then
		FullMapController:Close()
	end

	-- Start from whatever the player is wearing now, so reopening from Settings is an
	-- edit rather than a reset.
	local data = ProfileController:Get()
	if data ~= nil and data.Appearance ~= nil then
		choice.SkinId = data.Appearance.SkinId
		choice.PantId = data.Appearance.PantId
		choice.HairId = data.Appearance.HairId
		choice.FaceId = data.Appearance.FaceId
	end

	isOpen = true
	titleLabel.Text = if isFirstTime then "CREATE YOUR FIGHTER" else "APPEARANCE"
	closeButton.Visible = not isFirstTime
	applyButton.Text = if isFirstTime then "START TRAINING" else "APPLY"
	screen.Enabled = true

	self:_rebuild()
	preview()
	self:_refreshHeader()
	CustomizerStageController:Enter()
	self:_playEntrance()
end

function CustomizerController:Close()
	if not isOpen then
		return
	end
	isOpen = false
	screen.Enabled = false
	CustomizerStageController:Exit()

	-- Anything left unapplied is undone by repainting from what the server still says
	-- this character looks like.
	local character = currentCharacter()
	if character ~= nil then
		AppearanceController:Preview(
			character,
			character:GetAttribute("HairId") :: string,
			character:GetAttribute("FaceId") :: string
		)
	end
end

--[[
	Restates every selection mark after the working choice was replaced wholesale.
	The rows own their own highlighting, so the cheapest correct way to resync them is
	to press nothing and let each row read `choice` again — which is what rebuilding
	the rows does.
]]
function CustomizerController:_rebuild()
	for _, child in rows:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end

	heading(1, "BODY")
	swatchRow(2, "Skin", AppearanceConfig.SkinTones, "SkinId")
	swatchRow(3, "Shorts", AppearanceConfig.PantColors, "PantId")
	heading(4, "APPEAL")

	local hairIds, hairNames = {}, {}
	for _, style in HairConfig.Styles do
		table.insert(hairIds, style.Id)
		table.insert(hairNames, style.DisplayName)
	end
	stepperRow(5, "Hair", hairIds, hairNames, "HairId")

	local faceIds, faceNames = {}, {}
	for _, face in FaceConfig.Faces do
		table.insert(faceIds, face.Id)
		table.insert(faceNames, face.DisplayName)
	end
	stepperRow(6, "Face", faceIds, faceNames, "FaceId")

	UI.ApplyTheme(rows, UI.Dark)
end

function CustomizerController:Init()
	AppearanceController = Loader.Get("AppearanceController")
	CustomizerStageController = Loader.Get("CustomizerStageController")
	ProfileController = Loader.Get("ProfileController")
	ToastController = Loader.Get("ToastController")
end

--[[
	Lifts the boot curtain in ReplicatedFirst.

	Every path out of the first-join branch has to call this, including the ones that
	decide not to open anything. The curtain has its own timeout so a missed call is
	not fatal, but a player who sits behind an opaque screen for ten seconds because a
	branch forgot to speak has effectively lost the join.
]]
local function markBootReady()
	player:SetAttribute("BootReady", true)
end

--[[
	Waits until the character is actually ready to be framed.

	This replaces a flat `task.wait(1)` whose comment said "let the body finish dressing
	itself". The intent was right and the implementation was a guess: a second is dead
	time on a fast machine and not enough on a slow one, and neither case has anything
	to do with a clock. The three conditions below are what "dressed" actually means —
	the character exists, its root part exists, and the server's appearance pass has
	run, which is observable because AppearanceService.gate writes the Customizing
	attribute at the end of it.

	Every step has its own timeout and falls through rather than hanging. A creator
	framed on a half-built rig is a bad first second; a creator that never opens is a
	player stuck behind a curtain.
]]
local function waitForBody(): Model?
	local character = player.Character
	if character == nil then
		character = player.CharacterAdded:Wait()
	end
	if character == nil then
		return nil
	end

	if character:FindFirstChild("HumanoidRootPart") == nil then
		character:WaitForChild("HumanoidRootPart", 5)
	end

	if character:GetAttribute("Customizing") == nil then
		local ready = false
		local connection = character:GetAttributeChangedSignal("Customizing"):Connect(function()
			ready = true
		end)

		local deadline = os.clock() + 5
		while not ready and os.clock() < deadline do
			if character:GetAttribute("Customizing") ~= nil then
				break
			end
			task.wait()
		end
		connection:Disconnect()
	end

	return character
end

function CustomizerController:Start()
	self:_build()

	--[[
		The first-join open. It waits for the profile because Chosen is the only thing
		that distinguishes a new player from a returning one, and the profile arrives
		a moment after the character does.
	]]
	task.spawn(function()
		local data = ProfileController:WaitFor(20)
		if data == nil or data.Appearance == nil or data.Appearance.Chosen then
			-- Returning player, or a profile that never came. Either way there is
			-- nothing to open and no reason to hold the screen.
			markBootReady()
			return
		end

		waitForBody()

		if not isOpen then
			self:Open(true)
		end

		--[[
			One step, so the stage camera and the letterbox are actually in place. The
			curtain is above both, and lifting it a frame early shows the camera moving
			into position — the exact shot it exists to hide.

			Heartbeat, not RenderStepped. RenderStepped does not fire while the client
			is not rendering, so a player who alt-tabs across the join would park this
			thread forever and sit behind the curtain until its ten-second fallback.
			Caught exactly that way in Studio: the window lost focus mid-test and the
			curtain lifted on the timeout with BootReady still unset.
		]]
		task.wait()
		markBootReady()
	end)
end

return CustomizerController
