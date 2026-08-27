--!strict
--[[
	CustomizerStageController — everything that makes the character creator look like a
	character creator rather than a menu open in a gym.

	The split is deliberate: CustomizerController owns the choices and the panel, this
	file owns the theatre. The stage can be entered and left without anything knowing
	what a hairstyle is, and the panel can be edited without touching a light.

	What "expensive" is actually made of here, in rough order of how much it does:

	  * **Light.** A key light in front and above and a rim light behind and to the
	    side, tinted with the player's rank colour. Separating a body from its
	    background with a rim is the whole trick behind every product shot ever taken,
	    and it costs two PointLights.
	  * **A background that is not the gym.** A dark plane behind the figure with a
	    spot aimed at it, so the pool of light falls off into black. The gym is still
	    out there, blurred and drained of colour.
	  * **A camera that moves.** It dollies in on open and then turns slowly forever.
	    A still camera reads as a screenshot; anything moving reads as a production.
	  * **Letterbox bars**, which say "this is a sequence, not a screen" before the
	    player has read a single word.

	Every part and light is parented under `Workspace.CurrentCamera` — the project's
	established home for client-only visuals (VfxController, StationHighlightController
	and WaypointController all live there). Nothing replicates and nothing outlives the
	camera it hangs off.

	**Everything taken is given back.** The Lighting values are read at Enter and
	restored verbatim at Exit rather than reset to assumed defaults, because this runs
	over a world whose lighting other systems are entitled to have changed.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Modules.Loader)
local PosePlayback = require(ReplicatedStorage.Modules.PosePlayback)
local RankConfig = require(ReplicatedStorage.Modules.RankConfig)
local UI = require(ReplicatedStorage.Modules.UI)

local CustomizerStageController = {
	Name = "CustomizerStageController",
	-- After CustomizerController (47), which drives it.
	Priority = 48,
}

local FOLDER_NAME = "CustomizerStage"
local DOF_NAME = "CustomizerDepth"
-- Its own grade layer, stacked over the world's. See the Enter comment.
local GRADE_NAME = "CustomizerGrade"

-- Framing, in multiples of the character's own height. Everything here scales with
-- the body: a Titan is several times the size of a newbie, and a fixed stud distance
-- would frame one of them and lose the other entirely.
--
-- The camera sits at chest height rather than above the head. Looking down at someone
-- makes them small, which is the opposite of what a screen celebrating a body should
-- do; level with the sternum is how every fighter select frames its roster.
local CAMERA_BACK = 1.55
local CAMERA_UP = 0.1
local FOCUS_UP = 0.42
-- Pushed off-centre so the figure sits clear of the panel down the left.
local FRAME_SHIFT = 0.1
-- Where the dolly starts, as a multiple of the settled distance.
local DOLLY_FROM = 2.4
local DOLLY_SECONDS = 1.1

--[[
	The idle motion is a sway across the front, not a turntable.

	A continuous orbit sounds more impressive and is much worse: at seven degrees a
	second the camera is behind the player's head inside a minute, and the one thing
	this screen exists to show them is their own face. So the camera drifts a few
	degrees either side of front and always comes back, and anyone who wants to see
	the back can drag to it.
]]
local SWAY_DEGREES = 11
local SWAY_SPEED = 0.35
-- How fast a dragged view eases back to facing front once the throw has died.
local RETURN_RATE = 0.7
-- Degrees of spin per pixel dragged, and how fast a throw runs out.
local DRAG_SENSITIVITY = 0.42
local SPIN_DECAY = 3.4

local LETTERBOX_SCALE = 0.09
local LETTERBOX_SECONDS = 0.7
local FADE_SECONDS = 0.32

local BACKDROP_COLOR = Color3.fromRGB(16, 14, 18)
local KEY_COLOR = Color3.fromRGB(255, 244, 226)

local player = Players.LocalPlayer

local EffectsController: any = nil
local ProfileController: any = nil

local screen: ScreenGui
local topBar: Frame
local bottomBar: Frame
local fade: Frame

local staged = false
local stageFolder: Folder? = nil
local renderConnection: RBXScriptConnection? = nil
local inputConnections: { RBXScriptConnection } = {}

-- Turntable state. `spin` is where the player has dragged the view to, `velocity` is
-- what a throw left behind, and both are in degrees. The sway is added on top and is
-- not stored, so it never accumulates.
local spin = 0
local velocity = 0
local dragging = false
local dragTouch: InputObject? = nil
local lastDragX = 0
local elapsed = 0

--[[
	The HUD that steps aside while the creator is up.

	Named rather than "everything except us": PlayerGui also holds Roblox's own
	chrome and the toast layer, and a screen that swallowed the toast would eat the
	confirmation the player gets for saving.
]]
local HIDDEN_GUIS = {
	"GymHud",
	"GymTabBar",
	"GymMenuButton",
	"TrainingLoadGui",
}

-- The player's own overhead plate, which otherwise floats across the name headline
-- announcing the same person twice.
local NAMEPLATE_NAME = "GymNameplate"

-- What the world looked like before we touched it.
local restoreCamera: Enum.CameraType? = nil
local hidden: { ScreenGui } = {}
local hiddenPlate: BillboardGui? = nil

--[[
	The height of the figure being framed. Read once per frame from the head rather
	than cached: the muscle system rescales a body continuously, and a player who buys
	a physique class mid-session should not walk out of shot.
]]
local function figureHeight(character: Model): number
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid ~= nil and humanoid.HipHeight > 0 then
		return math.max(4, humanoid.HipHeight * 2.6)
	end
	return math.max(4, character:GetExtentsSize().Y)
end

local function buildStage(character: Model)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local height = figureHeight(character)

	-- The backdrop. Big enough that its edges never enter frame at any spin angle.
	local backdrop = Instance.new("Part")
	backdrop.Name = "Backdrop"
	-- Sized to swallow the whole frame at any orbit angle. An edge coming into shot
	-- and showing a lit gym behind it undoes the entire effect in one frame.
	backdrop.Size = Vector3.new(height * 26, height * 16, 1)
	backdrop.Color = BACKDROP_COLOR
	backdrop.Material = Enum.Material.SmoothPlastic
	backdrop.Anchored = true
	backdrop.CanCollide = false
	backdrop.CanQuery = false
	backdrop.CanTouch = false
	backdrop.CastShadow = false
	backdrop.Parent = folder

	-- A disc under the feet, so the figure is standing on something rather than
	-- floating in a void. Slightly lighter than the backdrop; the shadow falling on
	-- it is what sells the contact.
	--
	-- It is far wider than the shot needs because it is also doing the backdrop's job
	-- along the ground: the gym floor runs toward the camera, in front of anything
	-- standing behind the figure, and a lit strip of floorboards at the frame edge
	-- gives the whole thing away.
	local floor = Instance.new("Part")
	floor.Name = "Floor"
	floor.Shape = Enum.PartType.Cylinder
	floor.Size = Vector3.new(0.4, height * 11, height * 11)
	floor.Color = BACKDROP_COLOR:Lerp(Color3.new(1, 1, 1), 0.05)
	floor.Material = Enum.Material.Slate
	floor.Anchored = true
	floor.CanCollide = false
	floor.CanQuery = false
	floor.CanTouch = false
	floor.Parent = folder

	local function lamp(name: string, color: Color3, brightness: number, range: number): Part
		local holder = Instance.new("Part")
		holder.Name = name
		holder.Size = Vector3.one
		holder.Transparency = 1
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.CastShadow = false
		holder.Parent = folder

		local light = Instance.new("PointLight")
		light.Color = color
		light.Brightness = brightness
		light.Range = range
		light.Shadows = true
		light.Parent = holder
		return holder
	end

	lamp("KeyLight", KEY_COLOR, 3.4, height * 5)

	-- The rim is the player's rank colour, which is the one place in this screen where
	-- how far they have come shows up as light rather than as a number.
	local data = ProfileController:Get()
	local rank = if data ~= nil then RankConfig.GetById(data.SelectedTitleId) else nil
	local rimColor = if rank ~= nil then rank.Color else UI.Dark.Accent
	lamp("RimLight", rimColor, 5.5, height * 4)

	-- Aimed at the backdrop rather than the body: this is what makes the wall fall off
	-- into black at the edges instead of reading as a flat grey sheet.
	local pool = Instance.new("Part")
	pool.Name = "BackdropLight"
	pool.Size = Vector3.one
	pool.Transparency = 1
	pool.Anchored = true
	pool.CanCollide = false
	pool.CanQuery = false
	pool.CanTouch = false
	pool.CastShadow = false
	pool.Parent = folder

	local spot = Instance.new("SpotLight")
	spot.Color = rimColor:Lerp(Color3.new(1, 1, 1), 0.35)
	spot.Brightness = 2.2
	spot.Range = height * 8
	spot.Angle = 78
	spot.Face = Enum.NormalId.Front
	spot.Shadows = false
	spot.Parent = pool

	folder.Parent = camera
	stageFolder = folder
end

--[[
	Places the camera and everything hanging off it for one frame.

	All of it is recomputed every frame rather than parented to the character, because
	the body is being rescaled and repainted underneath and the backdrop has to stay
	square to a camera that is itself orbiting.
]]
local function humanoidRigType(character: Model): Enum.HumanoidRigType
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return if humanoid ~= nil then humanoid.RigType else Enum.HumanoidRigType.R15
end

local function place(deltaTime: number)
	local character = player.Character
	local camera = Workspace.CurrentCamera
	local folder = stageFolder
	if character == nil or camera == nil or folder == nil then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return
	end

	elapsed += deltaTime

	if dragging then
		velocity = 0
	else
		spin += velocity * deltaTime
		-- Exponential decay rather than a linear stop: a throw should ease out of the
		-- player's hand, not brake.
		velocity -= velocity * math.min(1, SPIN_DECAY * deltaTime)
		-- Once the throw is spent, the view drifts back to facing front on its own.
		if math.abs(velocity) < 8 then
			spin -= spin * math.min(1, RETURN_RATE * deltaTime)
		end
	end

	local sway = SWAY_DEGREES * math.sin(elapsed * SWAY_SPEED)

	local height = figureHeight(character)
	local focus = root.Position + Vector3.new(0, height * FOCUS_UP, 0)

	-- The dolly. Distance eases from wide to settled over the first second; after that
	-- the multiplier is 1 and this is a plain orbit.
	local alpha = math.clamp(elapsed / DOLLY_SECONDS, 0, 1)
	local eased = TweenService:GetValue(alpha, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local distance = height * CAMERA_BACK * (DOLLY_FROM + (1 - DOLLY_FROM) * eased)

	local turn = CFrame.new(root.Position) * CFrame.Angles(0, math.rad(spin + sway), 0)
	local offset = turn:VectorToWorldSpace(Vector3.new(0, height * CAMERA_UP, -distance))
	local eye = focus + offset
	-- Aiming a little to one side of the figure is what puts it off-centre without
	-- swinging the camera off its orbit.
	local aim = focus + turn:VectorToWorldSpace(Vector3.new(-height * FRAME_SHIFT, 0, 0))
	camera.CFrame = CFrame.lookAt(eye, aim)

	--[[
		Hold the head still.

		The idle poses include a glance to the side, which is good animation and awful
		timing: it fires every few seconds and turns the face away from the one screen
		whose entire job is showing the player their face. Writing identity here rather
		than editing the pose keeps the glance everywhere else in the game.

		This works because of the frame order, not by luck: GaitController writes the
		neck on PreSimulation, and a RenderStepped write is the last one to land before
		the frame is drawn. Same rule that decides which pose wins anywhere else.
	]]
	local neck = PosePlayback.FindJoint(character, humanoidRigType(character), "Neck")
	if neck ~= nil then
		neck.Transform = CFrame.identity
	end

	-- Keep the body in focus and everything past it soft. Without this the depth of
	-- field is focused wherever the last frame left it, which on a moving camera means
	-- the subject drifts in and out of sharpness.
	local dof = Lighting:FindFirstChild(DOF_NAME)
	if dof ~= nil and dof:IsA("DepthOfFieldEffect") then
		dof.FocusDistance = distance
		dof.InFocusRadius = height * 1.6
	end

	local toEye = (eye - focus)
	local flat = Vector3.new(toEye.X, 0, toEye.Z)
	if flat.Magnitude < 0.01 then
		return
	end
	local behind = -flat.Unit

	local backdrop = folder:FindFirstChild("Backdrop")
	if backdrop ~= nil and backdrop:IsA("BasePart") then
		backdrop.CFrame = CFrame.lookAt(focus + behind * (height * 2.2), focus)
	end

	local floor = folder:FindFirstChild("Floor")
	if floor ~= nil and floor:IsA("BasePart") then
		-- A cylinder lies along its own X, so a disc on the ground is one turned on
		-- its side — the same axis rule the face discs follow.
		floor.CFrame = CFrame.new(root.Position - Vector3.new(0, height * 0.5, 0))
			* CFrame.Angles(0, 0, math.rad(90))
	end

	local key = folder:FindFirstChild("KeyLight")
	if key ~= nil and key:IsA("BasePart") then
		key.Position = focus + turn:VectorToWorldSpace(Vector3.new(height * 0.6, height * 0.8, -height * 1.1))
	end

	local rim = folder:FindFirstChild("RimLight")
	if rim ~= nil and rim:IsA("BasePart") then
		rim.Position = focus + turn:VectorToWorldSpace(Vector3.new(-height * 0.9, height * 0.5, height * 0.9))
	end

	local pool = folder:FindFirstChild("BackdropLight")
	if pool ~= nil and pool:IsA("BasePart") then
		local at = focus + behind * (height * 1.1)
		pool.CFrame = CFrame.lookAt(at, at + behind)
	end
end

local function beginDrag(input: InputObject)
	dragging = true
	dragTouch = if input.UserInputType == Enum.UserInputType.Touch then input else nil
	lastDragX = input.Position.X
end

local function endDrag()
	dragging = false
	dragTouch = nil
end

--[[
	Turntable dragging, mouse and touch. Modelled on the map's pan handling in
	FullMapController: the touch that started the drag is remembered, because on a
	multi-touch screen every finger reports InputChanged and following the wrong one
	makes the figure jitter.
]]
local function bindInput()
	table.insert(
		inputConnections,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if processed then
				return
			end
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				beginDrag(input)
			end
		end)
	)

	table.insert(
		inputConnections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if not dragging then
				return
			end
			local isOurTouch = dragTouch ~= nil and input == dragTouch
			local isMouse = dragTouch == nil and input.UserInputType == Enum.UserInputType.MouseMovement
			if not isOurTouch and not isMouse then
				return
			end

			local delta = input.Position.X - lastDragX
			lastDragX = input.Position.X
			spin += delta * DRAG_SENSITIVITY
			-- Remember the throw so letting go coasts instead of stopping dead.
			velocity = delta * DRAG_SENSITIVITY * 26
		end)
	)

	table.insert(
		inputConnections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or (dragTouch ~= nil and input == dragTouch)
			then
				endDrag()
			end
		end)
	)
end

local function unbindInput()
	for _, connection in inputConnections do
		connection:Disconnect()
	end
	table.clear(inputConnections)
	endDrag()
end

function CustomizerStageController:_build()
	local playerGui = player:WaitForChild("PlayerGui")

	screen = Instance.new("ScreenGui")
	screen.Name = "GymCustomizerStage"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	-- Above the creator's own panel: bars and the fade are over everything.
	screen.DisplayOrder = 8
	screen.Enabled = false
	screen.Parent = playerGui

	local function bar(name: string, anchorY: number, positionY: number): Frame
		local frame = Instance.new("Frame")
		frame.Name = name
		frame.AnchorPoint = Vector2.new(0.5, anchorY)
		frame.Position = UDim2.fromScale(0.5, positionY)
		frame.Size = UDim2.fromScale(1, 0)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BorderSizePixel = 0
		frame.ZIndex = 10
		frame.Parent = screen
		return frame
	end

	topBar = bar("TopBar", 0, 0)
	bottomBar = bar("BottomBar", 1, 1)

	fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Visible = false
	fade.ZIndex = 20
	fade.Parent = screen
end

function CustomizerStageController:IsStaged(): boolean
	return staged
end

function CustomizerStageController:Enter()
	if staged then
		return
	end
	local character = player.Character
	local camera = Workspace.CurrentCamera
	if character == nil or camera == nil then
		return
	end
	staged = true

	spin = 0
	velocity = 0
	elapsed = 0

	restoreCamera = camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable

	buildStage(character)

	--[[
		The world pushed out of focus.

		Depth of field rather than a BlurEffect, and the difference is not subtle: a
		BlurEffect is a full-screen pass, so it smears the character just as hard as
		the gym behind them and turns the subject of the screen into a bruise. Depth of
		field is the only one of the two that can tell them apart, which is the entire
		reason it is here. `place` keeps the focus on the body as the camera moves.
	]]
	local dof = Instance.new("DepthOfFieldEffect")
	dof.Name = DOF_NAME
	dof.FarIntensity = 0
	dof.NearIntensity = 0
	dof.FocusDistance = 20
	dof.InFocusRadius = 12
	dof.Parent = Lighting
	TweenService:Create(dof, TweenInfo.new(0.7), { FarIntensity = 0.78 }):Play()

	--[[
		A grade of our own, layered over the world's rather than borrowed from it.

		This used to reach for `FindFirstChildOfClass("ColorCorrectionEffect")`, stash
		the values it found, and put them back on the way out. That worked only while
		exactly one grade existed and never changed underneath it. AtmosphereController
		now drives the world grade per district, so the saved values would go stale the
		moment a player crossed a boundary with the creator open, and leaving would
		paint the wrong district's colour back over the right one. Two layers compose;
		one layer taking turns does not.
	]]
	local grade = Instance.new("ColorCorrectionEffect")
	grade.Name = GRADE_NAME
	grade.Brightness = 0
	grade.Contrast = 0
	grade.Saturation = 0
	grade.Parent = Lighting
	--[[
		Mood, but **no saturation change**, and that is not a style choice.

		This graded the stage to -0.45 saturation, which is a lot: it turned Umber
		(129, 84, 52) into a pale peach on screen while the swatch button beside it —
		a ScreenGui, which no ColorCorrection touches — went on showing the true brown.
		So the player compared a graded body against an ungraded swatch, picked the
		colour that looked right under the grade, and then walked out into a world
		graded at only -0.12 and got something else again. "The skin I chose is not the
		skin I got" was exactly true, and nothing in the appearance pipeline was wrong.

		This is the one screen whose entire job is choosing a colour, so it is the one
		screen that may not restate it. Brightness and contrast stay — they set the mood
		without moving a hue — and the world's own grade still applies underneath, which
		is what makes the preview match where the player is about to stand.
	]]
	TweenService:Create(grade, TweenInfo.new(0.6), {
		Brightness = -0.12,
		Contrast = 0.1,
		Saturation = 0,
	}):Play()

	-- Only what was actually on screen is remembered, so leaving does not switch on a
	-- HUD the player had hidden for their own reasons.
	table.clear(hidden)
	local playerGui = player:FindFirstChild("PlayerGui")
	for _, name in HIDDEN_GUIS do
		local found = if playerGui ~= nil then playerGui:FindFirstChild(name) else nil
		if found ~= nil and found:IsA("ScreenGui") and found.Enabled then
			found.Enabled = false
			table.insert(hidden, found)
		end
	end

	local head = character:FindFirstChild("Head")
	local plate = if head ~= nil then head:FindFirstChild(NAMEPLATE_NAME) else nil
	if plate ~= nil and plate:IsA("BillboardGui") and plate.Enabled then
		plate.Enabled = false
		hiddenPlate = plate
	end

	screen.Enabled = true
	local bars = TweenInfo.new(LETTERBOX_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	TweenService:Create(topBar, bars, { Size = UDim2.fromScale(1, LETTERBOX_SCALE) }):Play()
	TweenService:Create(bottomBar, bars, { Size = UDim2.fromScale(1, LETTERBOX_SCALE) }):Play()

	renderConnection = RunService.RenderStepped:Connect(place)
	bindInput()

	EffectsController:Play("CustomizerReveal")
end

function CustomizerStageController:Exit()
	if not staged then
		return
	end
	staged = false

	unbindInput()
	if renderConnection ~= nil then
		renderConnection:Disconnect()
		renderConnection = nil
	end

	if stageFolder ~= nil then
		stageFolder:Destroy()
		stageFolder = nil
	end

	local dof = Lighting:FindFirstChild(DOF_NAME)
	if dof ~= nil then
		dof:Destroy()
	end

	-- Faded to neutral and then dropped, so nothing of ours outlives the stage. The
	-- world grade underneath was never touched and needs no restoring.
	local grade = Lighting:FindFirstChild(GRADE_NAME)
	if grade ~= nil then
		local fade = TweenService:Create(grade, TweenInfo.new(0.4), {
			Brightness = 0,
			Contrast = 0,
			Saturation = 0,
		})
		fade.Completed:Once(function()
			grade:Destroy()
		end)
		fade:Play()
	end

	local bars = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.In)
	TweenService:Create(topBar, bars, { Size = UDim2.fromScale(1, 0) }):Play()
	local closing = TweenService:Create(bottomBar, bars, { Size = UDim2.fromScale(1, 0) })
	closing:Play()
	closing.Completed:Once(function()
		if not staged then
			screen.Enabled = false
		end
	end)

	for _, gui in hidden do
		if gui.Parent ~= nil then
			gui.Enabled = true
		end
	end
	table.clear(hidden)

	local plate = hiddenPlate
	if plate ~= nil and plate.Parent ~= nil then
		plate.Enabled = true
	end
	hiddenPlate = nil

	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = restoreCamera or Enum.CameraType.Custom
	end
	restoreCamera = nil
end

--[[
	Fades to black, runs `during`, and fades back. Applying a look goes through here so
	the body changes behind a curtain rather than popping in front of the player.
]]
function CustomizerStageController:Curtain(during: () -> ())
	fade.Visible = true
	fade.BackgroundTransparency = 1

	local toBlack = TweenService:Create(fade, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 0 })
	toBlack:Play()
	toBlack.Completed:Wait()

	during()

	local toClear = TweenService:Create(fade, TweenInfo.new(FADE_SECONDS), { BackgroundTransparency = 1 })
	toClear:Play()
	toClear.Completed:Once(function()
		fade.Visible = false
	end)
end

function CustomizerStageController:Init()
	EffectsController = Loader.Get("EffectsController")
	ProfileController = Loader.Get("ProfileController")
end

function CustomizerStageController:Start()
	self:_build()
end

return CustomizerStageController
