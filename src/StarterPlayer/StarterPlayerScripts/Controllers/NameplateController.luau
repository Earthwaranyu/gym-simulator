--!strict
--[[
	NameplateController — who that is, and how close they are to going down.

	This game's whole hook is that other players interrupt your training, so the single
	most useful thing to know about someone across the plaza is whether they are nearly
	finished. Roblox's built-in nameplate does carry a health bar, but it is a hairline
	that only appears once someone is already hurt, drawn in a red that means nothing
	next to the red the HUD uses for damage taken — in the screenshot that prompted this
	it reads as an empty red outline, which is exactly the wrong impression of a player
	on full health.

	So the default is switched off and a real one drawn in its place, in the same green
	and red as your own bar at the bottom of the screen. One visual language: green is
	what is left, red is what has been taken, wherever it appears.

	Event-driven, not polled. A nameplate changes when someone is hit or respawns, which
	is a handful of times a minute, and the alternative is recomputing every plate on
	every frame for the entire server.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(ReplicatedStorage.Modules.UI)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local NameplateController = {
	Name = "NameplateController",
	Priority = 8,
}

-- How far above the head the plate floats.
local HEADROOM = 3.35
-- Past this the plate is not readable anyway, and drawing it is a BillboardGui the
-- engine has to lay out every frame for someone the player cannot even make out.
local MAX_DISTANCE = 150
local PLATE_WIDTH = 240
local PLATE_HEIGHT = 82

type Plate = {
	gui: BillboardGui,
	bar: UI.Bar,
	connections: { RBXScriptConnection },
}

local plates: { [Player]: Plate } = {}

function NameplateController:_clear(player: Player)
	local plate = plates[player]
	if plate == nil then
		return
	end
	for _, connection in plate.connections do
		connection:Disconnect()
	end
	plate.gui:Destroy()
	plates[player] = nil
end

--[[
	Builds the plate over one character.

	Adorned to the head rather than parented into the character model, so it travels with
	them and dies with them without any bookkeeping about limbs.

	A method rather than a local so a play session can build one against a known rig and
	read the result back; a solo test has no second player to wait for.
]]
function NameplateController:_attach(player: Player, character: Model)
	self:_clear(player)

	local head = character:WaitForChild("Head", 10)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if head == nil or not head:IsA("BasePart") or humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end

	-- One bar, not two. These are display-only properties, so setting them on another
	-- player's humanoid from here changes what this client draws and nothing else.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	local gui = Instance.new("BillboardGui")
	gui.Name = "GymNameplate"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(PLATE_WIDTH, PLATE_HEIGHT)
	gui.StudsOffsetWorldSpace = Vector3.new(0, HEADROOM, 0)
	-- Occluded by walls, like the machine signs. Seeing an enemy's health through a
	-- building would be a wallhack the game handed out for free.
	gui.AlwaysOnTop = false
	gui.MaxDistance = MAX_DISTANCE
	gui.ResetOnSpawn = false
	gui.Parent = head

	local title = UI.Label("Title", gui)
	title.Size = UDim2.new(1, 0, 0, 20)
	title.Font = UI.Font.Heading
	title.TextSize = 14
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextStrokeTransparency = 0.35

	-- Off unless the title asks for it. A stroke rather than a second glowing label:
	-- it survives being 14px tall at 150 studs, which is the whole point of a title
	-- somebody paid for.
	--
	-- One pixel, not two. The text is 14px and a two-pixel halo in its own colour
	-- closed the counters of the letters — a gold "VIP" read as a gold blob at any
	-- distance worth reading it from. Thin and mostly transparent is a rim light;
	-- thick is a smudge.
	local titleGlow = Instance.new("UIStroke")
	titleGlow.Thickness = 1
	titleGlow.Transparency = 0.35
	titleGlow.Enabled = false
	titleGlow.Parent = title

	local label = UI.Label("Name", gui)
	label.Position = UDim2.fromOffset(0, 21)
	label.Size = UDim2.new(1, 0, 0, 20)
	label.Font = UI.Font.Heading
	label.TextSize = 16
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextStrokeTransparency = 0.4
	label.Text = player.DisplayName

	local bar = UI.Bar("Health", UI.Palette.Vital, gui, UI.Palette.Health)
	bar.Root.Position = UDim2.fromOffset(0, 47)
	bar.Root.Size = UDim2.new(1, 0, 0, 28)
	bar.Caption.Font = UI.Font.Numeric
	bar.Caption.TextSize = 14
	bar.Caption.TextXAlignment = Enum.TextXAlignment.Center
	bar.Caption.Position = UDim2.fromOffset(0, 0)
	bar.Caption.Size = UDim2.fromScale(1, 1)

	local function refresh()
		local titleName = player:GetAttribute("TitleName")
		local titleColor = player:GetAttribute("TitleColor")
		title.Text = if type(titleName) == "string" then string.upper(titleName) else "NEWBIE"
		title.TextColor3 = if typeof(titleColor) == "Color3" then titleColor else UI.Palette.TextMuted
		local glowing = player:GetAttribute("TitleGlow") == true
		titleGlow.Color = title.TextColor3
		titleGlow.Enabled = glowing
		-- The dark drop shadow every plate carries is what a coloured halo has to
		-- fight; a glowing title drops it and lets its own colour do the separating.
		title.TextStrokeTransparency = if glowing then 0.75 else 0.35
		if humanoid.MaxHealth <= 0 then
			bar.Set(0, "—")
			return
		end
		-- The number as well as the length. Chest pushes max health into the thousands,
		-- so "half a bar" stops meaning a fixed amount of damage very early on.
		bar.Set(
			humanoid.Health / humanoid.MaxHealth,
			`HP  {NumberFormat.Format(math.max(0, humanoid.Health))} / {NumberFormat.Format(
				humanoid.MaxHealth
			)}`
		)
	end
	refresh()

	plates[player] = {
		gui = gui,
		bar = bar,
		connections = {
			humanoid.HealthChanged:Connect(refresh),
			-- Training Chest raises the ceiling mid-fight, and a bar that ignores that
			-- shows someone at full health as wounded until they next take a hit.
			humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh),
			player:GetAttributeChangedSignal("TitleName"):Connect(refresh),
			player:GetAttributeChangedSignal("TitleColor"):Connect(refresh),
			player:GetAttributeChangedSignal("TitleGlow"):Connect(refresh),
		},
	}
end

local function watch(player: Player)
	player.CharacterAdded:Connect(function(character)
		NameplateController:_attach(player, character)
	end)
	player.CharacterRemoving:Connect(function()
		NameplateController:_clear(player)
	end)

	if player.Character ~= nil then
		NameplateController:_attach(player, player.Character)
	end
end

function NameplateController:Start()
	for _, player in Players:GetPlayers() do
		-- Spawned, because attach waits for the head to replicate and a slow join
		-- should not hold up the rest of the loader.
		task.spawn(watch, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(watch, player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_clear(player)
	end)
end

return NameplateController
