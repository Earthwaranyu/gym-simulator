--!strict
--[[
	TrainingService — hold E to get on a machine, and the server takes over.

	Holding E on a station's proximity prompt puts the player onto one of the
	machine's training spots: they are moved onto the anchor, locked in place, and
	posed into the machine's exercise. Reps then tick on their own — there is no
	clicking and no stamina. Holding E again gets them off.

	Everything stays server-authoritative. ProximityPrompt.Triggered fires on the
	server and Roblox validates the distance before it does, so mounting needs no
	remote of our own, and once mounted the client sends nothing at all. There is no
	rep rate to forge: the loop below is the only thing that awards a rep.

	Stations are bound by CollectionService tag, so a level designer adds machines
	without touching code. Where a player ends up and how they are posed is data
	too — the anchor part's CFrame is used verbatim — so a bench that lays someone
	on their back and a bar that leaves them hanging are the same code path (see
	EquipmentConfig for the full model contract).

	Being locked to the machine is what makes the PvP hook bite. A training player
	cannot dodge, and Interrupt() throws them off and resets their combo, so the
	stagger is the entire cost of being attacked mid-set.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)

-- How long being hit keeps a player off the machines.
local STAGGER_SECONDS = 3
-- Combo grows this much per rep...
local COMBO_STEP = 0.02
-- ...up to this multiplier.
local MAX_COMBO_MULTIPLIER = 2
-- Ceiling on how often mid-set combo updates are pushed to a client.
local PUSH_INTERVAL = 0.25
-- Slack on the prompt's own distance check, in case a player is thrown while the
-- hold is in flight.
local MOUNT_SLACK = 6

type StationRecord = {
	definition: EquipmentConfig.EquipmentDefinition,
	-- What the platform this machine stands on multiplies its gains by. Resolved once
	-- when the station binds, because machines do not move between tiers at runtime.
	zoneMultiplier: number,
	zoneName: string?,
	anchors: { BasePart },
	exit: BasePart?,
	prompt: ProximityPrompt,
	-- Anchor index -> who is on it. Sparse, so #occupants is meaningless.
	occupants: { [number]: Player? },
}

type Session = {
	station: Instance,
	record: StationRecord,
	definition: EquipmentConfig.EquipmentDefinition,
	anchorIndex: number,
	anchorCFrame: CFrame,
	exitCFrame: CFrame,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	-- Humanoid properties as they were before the machine took them over.
	restore: { walkSpeed: number, jumpPower: number, jumpHeight: number, autoRotate: boolean },
	combo: number,
	lastRepAt: number,
}

local TrainingService = {
	Name = "TrainingService",
	Priority = 40,
}

local stations: { [Instance]: StationRecord } = {}
local sessions: { [Player]: Session } = {}
local staggeredUntil: { [Player]: number } = {}
local lastPushAt: { [Player]: number } = {}

local DataService: any = nil
local StatService: any = nil

-- (player, session-or-nil) — fired whenever a player mounts, dismounts, or reps.
TrainingService.TrainingChanged = Signal.new()

function TrainingService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")
end

--[[
	The living character parts a session needs, or nil if the player has none.
]]
local function resolveCharacter(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	if character == nil or character.Parent == nil then
		return nil, nil, nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return nil, nil, nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil, nil, nil
	end

	return character, humanoid, root
end

--[[
	Where to stand a player when they leave a machine.

	Machines provide a TrainExit part for this, because standing up in place puts
	you inside a bench or nine studs up a pull-up bar. Without one, fall back to
	standing upright on the spot: take the anchor's facing, flatten it, and if that
	is degenerate — which it is on any machine that lays you down, since "forward"
	there points at the ceiling — use its up axis instead.
]]
local function resolveExitCFrame(record: StationRecord, anchorCFrame: CFrame): CFrame
	local exit = record.exit
	if exit ~= nil and exit.Parent ~= nil then
		return exit.CFrame
	end

	local flat = Vector3.new(anchorCFrame.LookVector.X, 0, anchorCFrame.LookVector.Z)
	if flat.Magnitude < 0.1 then
		flat = Vector3.new(anchorCFrame.UpVector.X, 0, anchorCFrame.UpVector.Z)
	end
	if flat.Magnitude < 0.1 then
		flat = Vector3.zAxis
	end

	local position = anchorCFrame.Position
	return CFrame.lookAt(position, position + flat.Unit)
end

--[[
	The combo multiplier a session has built up. Exposed so the HUD can show it.
]]
function TrainingService:GetComboMultiplier(player: Player): number
	local session = sessions[player]
	if session == nil then
		return 1
	end
	return math.min(MAX_COMBO_MULTIPLIER, 1 + session.combo * COMBO_STEP)
end

function TrainingService:GetSession(player: Player): Session?
	return sessions[player]
end

function TrainingService:IsTraining(player: Player): boolean
	return sessions[player] ~= nil
end

function TrainingService:GetStaggerRemaining(player: Player): number
	local until_ = staggeredUntil[player]
	if until_ == nil then
		return 0
	end
	return math.max(0, until_ - os.clock())
end

local function buildState(player: Player, session: Session?): Types.TrainingState
	return {
		StationId = if session ~= nil then session.definition.Id else nil,
		Combo = if session ~= nil then session.combo else 0,
		StaggerSeconds = TrainingService:GetStaggerRemaining(player),
	}
end

function TrainingService:_push(player: Player)
	lastPushAt[player] = os.clock()
	local session = sessions[player]
	Net.Event("TrainingChanged"):FireClient(player, buildState(player, session))
	TrainingService.TrainingChanged:Fire(player, session)
end

--[[
	Republishes how many spots a station has free.

	Written onto the station model as attributes rather than sent over a remote:
	attributes replicate to every client on their own, which is what the billboards
	and the prompt label need, and no client can write them back.
]]
function TrainingService:_refreshOccupancy(station: Instance, record: StationRecord)
	local used = 0
	for _ in record.occupants do
		used += 1
	end

	local capacity = #record.anchors
	station:SetAttribute(EquipmentConfig.OCCUPANCY_ATTRIBUTE, used)
	station:SetAttribute(EquipmentConfig.CAPACITY_ATTRIBUTE, capacity)

	local label = record.definition.DisplayName
	if capacity > 1 or used > 0 then
		label ..= ` ({capacity - used}/{capacity} free)`
	end
	record.prompt.ObjectText = label
end

--[[
	The lowest-numbered free spot on a station, or nil when it is full.
]]
local function findFreeAnchor(record: StationRecord): number?
	for index = 1, #record.anchors do
		local occupant = record.occupants[index]
		if occupant == nil or occupant.Parent == nil then
			return index
		end
	end
	return nil
end

--[[
	Whether a machine is usable: either the player has out-levelled its power gate, or
	they bought the pass for it in the shop.
]]
function TrainingService:_isUnlocked(player: Player, definition: EquipmentConfig.EquipmentDefinition): boolean
	if StatService:GetTotalPower(player) >= definition.UnlockPower then
		return true
	end

	local data = DataService:GetData(player)
	return data ~= nil and data.OwnedEquipment[definition.Id] == true
end

--[[
	Puts a player onto a spot: moved to the anchor, locked there, and posed.

	The character is pivoted rather than having its root CFrame set, so every limb
	arrives at once instead of snapping into place a frame later. Anchoring the root
	is what holds them: the rest of the body hangs off it through the rig's motors,
	and an anchored part is not something a client can move.
]]
function TrainingService:_mount(player: Player, station: Instance, record: StationRecord, anchorIndex: number)
	local character, humanoid, root = resolveCharacter(player)
	if character == nil or humanoid == nil or root == nil then
		return
	end

	local anchor = record.anchors[anchorIndex]
	local anchorCFrame = anchor.CFrame
	local definition = record.definition

	local session: Session = {
		station = station,
		record = record,
		definition = definition,
		anchorIndex = anchorIndex,
		anchorCFrame = anchorCFrame,
		exitCFrame = resolveExitCFrame(record, anchorCFrame),
		character = character,
		humanoid = humanoid,
		root = root,
		restore = {
			walkSpeed = humanoid.WalkSpeed,
			jumpPower = humanoid.JumpPower,
			jumpHeight = humanoid.JumpHeight,
			autoRotate = humanoid.AutoRotate,
		},
		combo = 0,
		lastRepAt = os.clock(),
	}

	sessions[player] = session
	record.occupants[anchorIndex] = player

	humanoid.WalkSpeed = 0
	humanoid.JumpPower = 0
	humanoid.JumpHeight = 0
	humanoid.AutoRotate = false

	if character.PrimaryPart == nil then
		character.PrimaryPart = root
	end
	character:PivotTo(anchorCFrame)
	root.Anchored = true

	-- Which spot they are on, so clients can find the weights parked beside it and
	-- put them in this lifter's hands. Published before the pose attributes below,
	-- so a client reacting to the pose already has the anchor to work from.
	local anchorValue = Instance.new("ObjectValue")
	anchorValue.Name = EquipmentConfig.ANCHOR_VALUE_NAME
	anchorValue.Value = anchor
	anchorValue.Parent = character

	-- Every client animates every training player it can see, so which pose to run
	-- travels as a character attribute rather than a remote to one owner.
	character:SetAttribute(PoseConfig.POSE_ATTRIBUTE, definition.PoseId)
	character:SetAttribute(PoseConfig.INTERVAL_ATTRIBUTE, definition.RepInterval)

	self:_refreshOccupancy(station, record)
	self:_push(player)
end

--[[
	Takes a player off their machine and hands control back.

	Restoring is deliberately defensive: a player can be dismounted because their
	character was destroyed under them, so every step re-checks that what it is
	putting back still exists.
]]
function TrainingService:_dismount(player: Player, moveToExit: boolean)
	local session = sessions[player]
	if session == nil then
		return
	end

	sessions[player] = nil

	if session.record.occupants[session.anchorIndex] == player then
		session.record.occupants[session.anchorIndex] = nil
	end
	self:_refreshOccupancy(session.station, session.record)

	local character = session.character
	if character.Parent ~= nil then
		character:SetAttribute(PoseConfig.POSE_ATTRIBUTE, nil)
		character:SetAttribute(PoseConfig.INTERVAL_ATTRIBUTE, nil)

		-- Clearing this is what sends the weights back to their rack.
		local anchorValue = character:FindFirstChild(EquipmentConfig.ANCHOR_VALUE_NAME)
		if anchorValue ~= nil then
			anchorValue:Destroy()
		end
	end

	local root = session.root
	if root.Parent ~= nil then
		root.Anchored = false
	end

	local humanoid = session.humanoid
	if humanoid.Parent ~= nil then
		humanoid.WalkSpeed = session.restore.walkSpeed
		humanoid.JumpPower = session.restore.jumpPower
		humanoid.JumpHeight = session.restore.jumpHeight
		humanoid.AutoRotate = session.restore.autoRotate
	end

	-- Skipped when the character is already gone or dead, where teleporting a
	-- ragdolling body to the exit pad would look like a bug rather than a courtesy.
	if moveToExit and character.Parent ~= nil and humanoid.Parent ~= nil and humanoid.Health > 0 then
		character:PivotTo(session.exitCFrame)
	end

	self:_push(player)
end

--[[
	Ends a set. Safe to call for a player who is not training.
]]
function TrainingService:Stop(player: Player)
	self:_dismount(player, true)
end

--[[
	Knocks a player off their machine and resets their combo.

	This is the training interrupt, and the whole reason PvP exists in this game.
	CombatService calls it whenever a training player is hit. Because training is
	otherwise automatic and costless, the stagger — plus the walk back and the E
	hold to remount — is what makes attacking someone mid-set actually annoying.
]]
function TrainingService:Interrupt(player: Player)
	local wasTraining = sessions[player] ~= nil

	staggeredUntil[player] = os.clock() + STAGGER_SECONDS
	self:_dismount(player, false)

	if wasTraining then
		Net.Event("Notify"):FireClient(player, "Knocked off the machine!")
	else
		self:_push(player)
	end
end

--[[
	Someone held E on a station.

	One prompt serves the whole machine, so this is both "get on" and "get off":
	triggering the station you are already on leaves it, which is why the player
	never has to find a second key.
]]
function TrainingService:_onTriggered(player: Player, station: Instance)
	local record = stations[station]
	if record == nil then
		return
	end

	local existing = sessions[player]
	if existing ~= nil and existing.station == station then
		self:Stop(player)
		return
	end

	local stagger = self:GetStaggerRemaining(player)
	if stagger > 0 then
		Net.Event("Notify"):FireClient(player, `Still recovering — {string.format("%.1f", stagger)}s`)
		return
	end

	if DataService:GetData(player) == nil then
		return
	end

	local character, _humanoid, root = resolveCharacter(player)
	if character == nil or root == nil then
		return
	end

	local definition = record.definition
	if not self:_isUnlocked(player, definition) then
		Net.Event("Notify"):FireClient(
			player,
			`{definition.DisplayName} needs {NumberFormat.Format(definition.UnlockPower)} power`
		)
		return
	end

	local anchorIndex = findFreeAnchor(record)
	if anchorIndex == nil then
		Net.Event("Notify"):FireClient(player, `{definition.DisplayName} is in use`)
		return
	end

	-- The prompt already enforced its own range, but a player mid-knockback can
	-- travel during the hold. Re-check against the spot they would actually take.
	local anchor = record.anchors[anchorIndex]
	if (root.Position - anchor.Position).Magnitude > EquipmentConfig.PROMPT_DISTANCE + MOUNT_SLACK then
		return
	end

	-- Switching machines starts a fresh combo, so a built-up multiplier cannot be
	-- carried between stations.
	if existing ~= nil then
		self:_dismount(player, false)
	end

	self:_mount(player, station, record, anchorIndex)
	Net.Event("Notify"):FireClient(player, `Training on {definition.DisplayName} — hold E to stop`)
end

--[[
	Binds a tagged station: reads its definition, finds its spots, and gives it the
	prompt players hold E on. Misconfigured models are reported and skipped, never
	fatal — one bad machine should not take the gym down.
]]
function TrainingService:_bindStation(station: Instance)
	if stations[station] ~= nil then
		return
	end

	local definition, reason = EquipmentConfig.Resolve(station)
	if definition == nil then
		warn(`[TrainingService] Ignoring {station:GetFullName()}: {reason}`)
		return
	end

	local anchors = EquipmentConfig.GetAnchors(station)
	if #anchors == 0 then
		warn(
			`[TrainingService] Ignoring {station:GetFullName()}: no part named `
				.. `"{EquipmentConfig.ANCHOR_NAME}" to stand a player on`
		)
		return
	end

	local base = EquipmentConfig.GetBase(station)
	if base == nil then
		warn(`[TrainingService] Ignoring {station:GetFullName()}: no BasePart to attach a prompt to`)
		return
	end

	local exit = station:FindFirstChild(EquipmentConfig.EXIT_NAME, true)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TrainPrompt"
	prompt.ActionText = definition.ActionText
	prompt.ObjectText = definition.DisplayName
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = EquipmentConfig.PROMPT_HOLD_SECONDS
	prompt.MaxActivationDistance = EquipmentConfig.PROMPT_DISTANCE
	-- Machines are big and cluttered with their own geometry, so requiring line of
	-- sight mostly means the prompt vanishing when you stand where you should.
	prompt.RequiresLineOfSight = false
	prompt.Parent = base

	-- A machine is worth whatever tier it stands in. Resolving by containment rather
	-- than by an attribute means a designer tiers a machine by placing it, and cannot
	-- leave a bench in Titan Forge still paying Garage rates.
	local zone = ZoneConfig.AtPosition(base.Position)
	if zone == nil then
		warn(
			`[TrainingService] {station:GetFullName()} stands outside every "{ZoneConfig.ZONE_TAG}" `
				.. `volume, so it pays base rate. Put it inside one to tier it.`
		)
	end

	local record: StationRecord = {
		definition = definition,
		zoneMultiplier = if zone ~= nil then zone.GainMultiplier else 1,
		zoneName = if zone ~= nil then zone.DisplayName else nil,
		anchors = anchors,
		exit = if exit ~= nil and exit:IsA("BasePart") then exit else nil,
		prompt = prompt,
		occupants = {},
	}
	stations[station] = record

	prompt.Triggered:Connect(function(player: Player)
		self:_onTriggered(player, station)
	end)

	self:_refreshOccupancy(station, record)
end

function TrainingService:_unbindStation(station: Instance)
	local record = stations[station]
	if record == nil then
		return
	end

	for _, occupant in record.occupants do
		self:_dismount(occupant, false)
	end

	record.prompt:Destroy()
	stations[station] = nil
end

--[[
	One tick for one mounted player: confirm they are still fit to train, then pay
	out a rep when the machine's interval is up.
]]
function TrainingService:_step(player: Player, session: Session, now: number)
	if session.character.Parent == nil or session.humanoid.Health <= 0 or session.root.Parent == nil then
		self:_dismount(player, false)
		return
	end

	if DataService:GetData(player) == nil then
		self:_dismount(player, false)
		return
	end

	if now - session.lastRepAt < session.definition.RepInterval then
		return
	end

	session.lastRepAt = now
	session.combo += 1

	-- Cheap insurance that nothing has nudged the player off their spot. Writing an
	-- identical CFrame is a no-op, so this costs no replication in the normal case.
	session.root.CFrame = session.anchorCFrame

	local gain = session.definition.BaseGain * self:GetComboMultiplier(player) * session.record.zoneMultiplier
	StatService:AddStat(player, session.definition.StatId, gain)

	if now - (lastPushAt[player] or 0) >= PUSH_INTERVAL then
		self:_push(player)
	end
end

function TrainingService:Start()
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		self:_bindStation(station)
	end

	CollectionService:GetInstanceAddedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_bindStation(station)
	end)

	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_unbindStation(station)
	end)

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			-- A new body is never mid-set, and never still staggered from the last one.
			self:_dismount(player, false)
			staggeredUntil[player] = nil

			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid ~= nil and humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					self:_dismount(player, false)
				end)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		self:_dismount(player, false)
		staggeredUntil[player] = nil
		lastPushAt[player] = nil
	end)

	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for player, session in sessions do
			self:_step(player, session, now)
		end
	end)
end

return TrainingService
