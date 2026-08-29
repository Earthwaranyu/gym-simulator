--!strict
--[[
	MobNameplateController — a monster's name and how much of it is left.

	Monsters wore Roblox's default plate: the engine's own hairline health bar, in the
	engine's own font, floating at the engine's own height. NameplateController exists
	precisely because that is not good enough for a player, and a monster is the thing
	you spend a fight staring at — you could not tell a Stormcaller at full health from
	one a punch away from dying.

	A sibling rather than an extension. GaitController, StrikeController and
	FlinchController all took mobs by adding six lines, because their internals are keyed
	by Model; NameplateController is keyed by Player from top to bottom, and bending it
	into a shape that serves both would leave two half-general things instead of two clear
	ones. What is worth sharing is shared: the same UI.Bar with the same two colours, so a
	monster's health reads exactly like a player's.

	Everything is event-driven. There can be forty-nine of these alive at once — six
	thieves in each of seven fields, plus the bosses — and polling that many humanoids
	every frame to redraw a bar that mostly has not changed is a cost with nothing to show
	for it.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UI = require(ReplicatedStorage.Modules.UI)
local MobConfig = require(ReplicatedStorage.Modules.MobConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)

local MobNameplateController = {
	Name = "MobNameplateController",
	Priority = 8,
}

local HEADROOM = 1.4

-- How long to wait for a streaming rig to finish arriving. The same budget the player
-- nameplate allows for a character.
local BIND_TIMEOUT = 10

-- A thief only matters once you are close enough to be in trouble. A boss has to be
-- legible from the rim of its own arena, which is seventy studs from the middle, and
-- from far enough out to decide whether to walk in at all.
local THIEF_DISTANCE = 150
local BOSS_DISTANCE = 250

local THIEF_PLATE = Vector2.new(200, 52)
local BOSS_PLATE = Vector2.new(280, 68)

type Plate = {
	gui: BillboardGui,
	connections: { RBXScriptConnection },
}

local plates: { [Instance]: Plate } = {}

function MobNameplateController:_unbind(model: Instance)
	local plate = plates[model]
	if plate == nil then
		return
	end
	plates[model] = nil
	for _, connection in plate.connections do
		connection:Disconnect()
	end
	plate.gui:Destroy()
end

function MobNameplateController:_bind(model: Instance)
	if plates[model] ~= nil or not model:IsA("Model") then
		return
	end

	local definition = MobConfig.Resolve(model)
	if definition == nil then
		return
	end

	-- Wait for the rig rather than give up on it. This yields, which is the whole point:
	-- a boss is created wherever its timer says, usually nowhere near you, so with
	-- streaming it does not reach this client until you travel to the arena — and a
	-- model that streams in delivers its descendants over several frames. Looking once
	-- and returning meant every boss went bar-less for its entire life, while thieves
	-- were fine because a field only ever spawns one within four hundred studs of a
	-- player, well inside the streaming radius, arriving complete.
	local head = model:WaitForChild("Head", BIND_TIMEOUT)
	local humanoid = model:WaitForChild("Humanoid", BIND_TIMEOUT)
	if head == nil or not head:IsA("BasePart") or humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end

	-- Everything can have changed across those yields: the monster may have died,
	-- despawned, or streamed back out and in again, and the tag signal fires afresh on a
	-- re-stream. The player nameplate never has to think about this because a character
	-- is not streamed away from its own owner.
	if model.Parent == nil or plates[model] ~= nil then
		return
	end

	-- One bar, not two. Display-only properties, so this changes what this client draws
	-- and nothing about the monster.
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	local boss = definition.Kind == "Boss"
	local size = if boss then BOSS_PLATE else THIEF_PLATE

	local gui = Instance.new("BillboardGui")
	gui.Name = "GymMobPlate"
	gui.Adornee = head
	gui.Size = UDim2.fromOffset(size.X, size.Y)
	-- Measured off the whole model, because a boss is 2.1 times a thief and a flat
	-- offset would sit inside its horns.
	gui.StudsOffsetWorldSpace = UI.HeadroomOffset(model, head, HEADROOM * definition.Scale)
	-- Occluded by walls, matching the player plates. Reading a boss's health through the
	-- side of its arena would be a free wallhack.
	gui.AlwaysOnTop = false
	gui.MaxDistance = if boss then BOSS_DISTANCE else THIEF_DISTANCE
	gui.Parent = head

	local name = UI.Label("Name", gui)
	name.Size = UDim2.new(1, 0, 0, if boss then 24 else 20)
	name.Font = UI.Font.Heading
	name.TextSize = if boss then 19 else 15
	name.TextXAlignment = Enum.TextXAlignment.Center
	name.TextStrokeTransparency = 0.35
	name.TextColor3 = if boss then UI.Palette.Danger else UI.Palette.Text
	name.Text = string.upper(definition.DisplayName)

	local bar = UI.Bar("Health", UI.Palette.Vital, gui, UI.Palette.Health)
	bar.Root.Position = UDim2.fromOffset(0, if boss then 28 else 23)
	bar.Root.Size = UDim2.new(1, 0, 0, if boss then 30 else 24)
	bar.Caption.Font = UI.Font.Numeric
	bar.Caption.TextSize = if boss then 14 else 12
	bar.Caption.TextXAlignment = Enum.TextXAlignment.Center
	bar.Caption.Position = UDim2.fromOffset(0, 0)
	bar.Caption.Size = UDim2.fromScale(1, 1)

	local function refresh()
		if humanoid.MaxHealth <= 0 then
			bar.Set(0, "—")
			return
		end
		-- The number as well as the length: a Stormcaller has three billion health, and
		-- "most of a bar left" is not something a player can act on when a single punch
		-- moves it by a sixtieth.
		bar.Set(
			humanoid.Health / humanoid.MaxHealth,
			`{NumberFormat.Format(math.max(0, humanoid.Health))} / {NumberFormat.Format(humanoid.MaxHealth)}`
		)
	end
	refresh()

	plates[model] = {
		gui = gui,
		connections = {
			humanoid.HealthChanged:Connect(refresh),
			humanoid:GetPropertyChangedSignal("MaxHealth"):Connect(refresh),
			-- A boss walking out of its leash heals to full, and a bar still showing a
			-- sliver would be the only thing on screen saying otherwise.
			humanoid.Died:Connect(function()
				bar.Set(0, "DOWN")
			end),
		},
	}
end

function MobNameplateController:Start()
	for _, model in CollectionService:GetTagged(MobConfig.MOB_TAG) do
		task.spawn(function()
			self:_bind(model)
		end)
	end
	CollectionService:GetInstanceAddedSignal(MobConfig.MOB_TAG):Connect(function(instance: Instance)
		-- Spawned in a thread because _bind waits for the rig to finish streaming in, and
		-- a tag signal is not somewhere to yield.
		task.spawn(function()
			self:_bind(instance)
		end)
	end)
	CollectionService:GetInstanceRemovedSignal(MobConfig.MOB_TAG):Connect(function(instance: Instance)
		self:_unbind(instance)
	end)
end

return MobNameplateController
