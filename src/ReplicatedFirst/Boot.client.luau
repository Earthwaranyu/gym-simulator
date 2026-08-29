--!strict
--[[
	Boot — the curtain that covers the join.

	Everything else this game draws lives in StarterPlayerScripts, which cannot run
	until the character is already loading. That is why the world used to be on screen
	for a second or two before the fighter creator opened: not because the creator was
	slow to build (it is built synchronously in Start), but because the client cannot
	know whether a player is new until their profile has made a DataStore round trip,
	and that trip is network-bound. It cannot be removed. It can only be hidden.

	So this is the one script in the project that runs from ReplicatedFirst, and its
	entire job is to be on screen before anything else is.

	It deliberately requires nothing. ReplicatedFirst runs before ReplicatedStorage has
	necessarily replicated, so a `require` of the shared UI module would mean a
	WaitForChild here — reintroducing, at the very front of the boot, exactly the delay
	this exists to cover. The two colours below are therefore written out rather than
	read from UI.Palette, and they must be kept in step with it by hand.

	The lift is an attribute rather than a shared signal for the same reason: an
	attribute needs nothing to have loaded first. CustomizerController sets BootReady
	once it has either opened the creator or established that this player already has a
	fighter.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local TweenService = game:GetService("TweenService")

-- Mirrors UI.Palette.Backdrop and UI.Palette.Text. See the header for why these are
-- copied rather than required.
local BACKDROP = Color3.fromRGB(232, 228, 216)
local INK = Color3.fromRGB(38, 33, 26)
local ACCENT = Color3.fromRGB(178, 108, 12)

--[[
	The curtain lifts on its own after this long no matter what.

	This is the only behaviour in the file that must not depend on anything else
	working. If the profile never arrives, or CustomizerController throws before it can
	set the attribute, a player behind an opaque full-screen frame has no game at all —
	a wrong-looking join is recoverable, a black screen is not.
]]
local FALLBACK_SECONDS = 10
local FADE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local player = Players.LocalPlayer

ReplicatedFirst:RemoveDefaultLoadingScreen()

local screen = Instance.new("ScreenGui")
screen.Name = "GymBoot"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
-- Above the customizer (7) and its stage (8), because it has to cover the camera move
-- those two make on the way in.
screen.DisplayOrder = 10000
screen.Parent = player:WaitForChild("PlayerGui")

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.BackgroundColor3 = BACKDROP
backdrop.BorderSizePixel = 0
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.Parent = screen

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.47)
title.Size = UDim2.fromScale(0.8, 0.1)
title.Font = Enum.Font.GothamBold
title.TextScaled = true
title.TextColor3 = INK
title.Text = "HYPER GYM"
title.Parent = backdrop

local titleSize = Instance.new("UITextSizeConstraint")
titleSize.MaxTextSize = 44
titleSize.Parent = title

-- A moving element, so a join that is waiting on a slow DataStore reads as loading
-- rather than as frozen.
local pulse = Instance.new("Frame")
pulse.Name = "Pulse"
pulse.AnchorPoint = Vector2.new(0.5, 0.5)
pulse.Position = UDim2.fromScale(0.5, 0.56)
pulse.Size = UDim2.fromOffset(40, 3)
pulse.BackgroundColor3 = ACCENT
pulse.BorderSizePixel = 0
pulse.Parent = backdrop

local pulseCorner = Instance.new("UICorner")
pulseCorner.CornerRadius = UDim.new(1, 0)
pulseCorner.Parent = pulse

TweenService:Create(
	pulse,
	TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
	{ Size = UDim2.fromOffset(140, 3) }
):Play()

--[[
	Waits for the game to say it is ready, or gives up.

	Returns either way; the caller lifts the curtain regardless of which happened.
]]
local function waitForReady()
	if player:GetAttribute("BootReady") == true then
		return
	end

	local done = false
	local changed: RBXScriptConnection? = nil

	changed = player:GetAttributeChangedSignal("BootReady"):Connect(function()
		if player:GetAttribute("BootReady") == true then
			done = true
		end
	end)

	local deadline = os.clock() + FALLBACK_SECONDS
	while not done and os.clock() < deadline do
		task.wait()
	end

	if changed ~= nil then
		changed:Disconnect()
	end
end

waitForReady()

TweenService:Create(backdrop, FADE, { BackgroundTransparency = 1 }):Play()
TweenService:Create(title, FADE, { TextTransparency = 1 }):Play()
TweenService:Create(pulse, FADE, { BackgroundTransparency = 1 }):Play()

task.wait(FADE.Time)
screen:Destroy()
