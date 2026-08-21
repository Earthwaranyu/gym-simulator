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
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local AppearanceConfig = require(ReplicatedStorage.Modules.AppearanceConfig)
local FaceConfig = require(ReplicatedStorage.Modules.FaceConfig)
local HairConfig = require(ReplicatedStorage.Modules.HairConfig)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local UI = require(ReplicatedStorage.Modules.UI)

local CustomizerController = {
	Name = "CustomizerController",
	-- After AppearanceController (45), whose Preview it drives.
	Priority = 47,
}

local PANEL_SIZE = Vector2.new(380, 470)
local ROW_HEIGHT = 46
local SWATCH_SIZE = 30

-- Where the camera stands relative to the character while the panel is open: back,
-- up a little, and looking at the chest rather than the feet.
local CAMERA_BACK = 11
local CAMERA_UP = 2.6
local CAMERA_FOCUS_UP = 1.6

local player = Players.LocalPlayer

local AppearanceController: any = nil
local EffectsController: any = nil
local ProfileController: any = nil
local ToastController: any = nil

local screen: ScreenGui
local rows: Frame
local applyButton: TextButton
local closeButton: TextButton
local titleLabel: TextLabel

local isOpen = false
local cameraConnection: RBXScriptConnection? = nil
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
			OnPress = function()
				EffectsController:Play("UiClick")
			end,
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
			OnPress = function()
				EffectsController:Play("UiClick")
			end,
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
	panel.AnchorPoint = Vector2.new(0, 0.5)
	panel.Position = UDim2.new(0, 34, 0.5, 0)
	panel.Size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y)
	panel.BackgroundTransparency = 0.06
	panel.Active = true

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = PANEL_SIZE.X / PANEL_SIZE.Y
	aspect.Parent = panel

	titleLabel = UI.Label("Title", panel)
	titleLabel.Size = UDim2.new(1, -44, 0, 34)
	titleLabel.Font = UI.Font.Heading
	titleLabel.TextSize = 18
	titleLabel.Text = "APPEARANCE"

	closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.fromScale(1, 0)
	closeButton.Size = UDim2.fromOffset(32, 32)
	closeButton.BackgroundColor3 = UI.Palette.Backdrop
	closeButton.BackgroundTransparency = 0.2
	closeButton.BorderSizePixel = 0
	closeButton.AutoButtonColor = false
	closeButton.Font = UI.Font.Heading
	closeButton.TextSize = 16
	closeButton.TextColor3 = UI.Palette.TextMuted
	closeButton.Text = "✕"
	UI.Role(closeButton, { Ink = "TextMuted", Fill = "Backdrop" })
	closeButton.Parent = panel

	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 8)
	closeCorner.Parent = closeButton

	UI.Pressable(closeButton)
	closeButton.Activated:Connect(function()
		self:Close()
	end)

	rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromOffset(0, 38)
	rows.Size = UDim2.new(1, 0, 1, -96)
	rows.BackgroundTransparency = 1
	rows.Parent = panel
	UI.VerticalList(rows, 8)

	applyButton = Instance.new("TextButton")
	applyButton.Name = "Apply"
	applyButton.AnchorPoint = Vector2.new(0.5, 1)
	applyButton.Position = UDim2.fromScale(0.5, 1)
	applyButton.Size = UDim2.new(1, 0, 0, 46)
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
		OnPress = function()
			EffectsController:Play("UiClick")
		end,
	})

	applyButton.Activated:Connect(function()
		self:_apply()
	end)

	-- The panel floats over the world rather than inside a menu page, so it takes the
	-- dark chrome the HUD uses instead of the cream menu paper.
	UI.ApplyTheme(screen, UI.Dark)
end

function CustomizerController:_apply()
	applyButton.Text = "SAVING…"

	local ok, message = Net.Function("SetAppearance"):InvokeServer({
		SkinId = choice.SkinId,
		PantId = choice.PantId,
		HairId = choice.HairId,
		FaceId = choice.FaceId,
	})

	applyButton.Text = "APPLY"
	ToastController:Show(message, if ok then UI.Palette.Vital else UI.Palette.Danger)

	if ok then
		self:Close()
	end
end

--[[
	Points the camera at the player's own body.

	Bound to a render step rather than set once: the character keeps breathing, the
	gait system keeps moving it, and the muscle system rescales it. A single CFrame
	written at open time drifts off the body within a few seconds.
]]
local function holdCamera()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable

	cameraConnection = RunService.RenderStepped:Connect(function()
		local character = currentCharacter()
		local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
		if root == nil or not root:IsA("BasePart") then
			return
		end

		local focus = root.Position + Vector3.new(0, CAMERA_FOCUS_UP, 0)
		local from = root.CFrame * CFrame.new(0, CAMERA_UP, -CAMERA_BACK)
		camera.CFrame = CFrame.lookAt(from.Position, focus)
	end)
end

local function releaseCamera()
	if cameraConnection ~= nil then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Custom
	end
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
	holdCamera()
end

function CustomizerController:Close()
	if not isOpen then
		return
	end
	isOpen = false
	screen.Enabled = false
	releaseCamera()

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
	EffectsController = Loader.Get("EffectsController")
	ProfileController = Loader.Get("ProfileController")
	ToastController = Loader.Get("ToastController")
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
			return
		end
		-- Let the body finish dressing itself; opening onto a half-built rig frames
		-- the camera on a character that is about to change size.
		task.wait(1)
		if not isOpen then
			self:Open(true)
		end
	end)
end

return CustomizerController
