--!strict
--[[
	TrainingService — hold E to get on a machine, and the server takes over.

	Holding E on a station's proximity prompt puts the player onto one of the
	machine's training spots: they are moved onto the anchor, locked in place, and
	posed into the machine's exercise. Reps then tick on their own — there is no
	clicking and no stamina. Holding E again, pressing Space, or jumping gets
	them off.

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
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Packages.Signal)
local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local Types = require(ReplicatedStorage.Modules.Types)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local PoseConfig = require(ReplicatedStorage.Modules.PoseConfig)
local Formulas = require(ReplicatedStorage.Modules.Formulas)
local WeightConfig = require(ReplicatedStorage.Modules.WeightConfig)
local MuscleDefinitionConfig = require(ReplicatedStorage.Modules.MuscleDefinitionConfig)

-- How long being hit keeps a player off the machines.
local STAGGER_SECONDS = 3
-- A full uninterrupted set earns one clear, whole-number boost. The former 2%-per-tick
-- curve stored fractional stats, so a visible stat could jump +1 and then +2 even
-- though the machine label had not changed.
local COMBO_GOAL = 50
local MAX_COMBO_MULTIPLIER = 2
-- Ceiling on how often mid-set combo updates are pushed to a client.
local PUSH_INTERVAL = 0.25
-- Slack on the prompt's own distance check, in case a player is thrown while the
-- hold is in flight.
local MOUNT_SLACK = 6

type PromptRecord = {
	prompt: ProximityPrompt,
	copy: Instance,
	anchorIndices: { number },
}

type StationRecord = {
	definition: EquipmentConfig.EquipmentDefinition,
	-- What the platform this machine stands on multiplies its gains by. Resolved once
	-- when the station binds, because machines do not move between tiers at runtime.
	zoneMultiplier: number,
	-- What the district demands of anyone who wants to use its machines. Gain
	-- rides on the zone, so mounting has to as well — see _onTriggered.
	zoneRequiredStat: number,
	zoneId: string,
	zoneName: string?,
	anchors: { BasePart },
	exit: BasePart?,
	prompts: { PromptRecord },
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
	lastGainAt: number,
	weightKg: number,
	-- The recommendation the client was last told about, so a stat change can tell
	-- whether it opened up a new load or merely moved the number.
	lastRecommended: number,
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

local function effectiveRepInterval(session: Session, tier: WeightConfig.WeightTier): number
	return session.definition.RepInterval * WeightConfig.TempoMultiplier(tier, session.weightKg)
end

-- (player, session-or-nil) — fired whenever a player mounts, dismounts, or reps.
TrainingService.TrainingChanged = Signal.new()

function TrainingService:Init()
	DataService = Loader.Get("DataService")
	StatService = Loader.Get("StatService")

	-- Rate-limited like every other remote. The Train panel polls this while it is
	-- open, so the budget allows a steady refresh and nothing more.
	Net.BindFunction("GetSpotStatus", 3, function(player: Player)
		return self:GetSpotStatus(player)
	end)

	Net.BindFunction("SetTrainingWeight", 4, function(player: Player, requestedKg: any)
		if type(requestedKg) ~= "number" then
			return false, "Invalid weight."
		end

		local session = sessions[player]
		local data = DataService:GetData(player)
		if session == nil or data == nil then
			return false, "Get on a machine before choosing its load."
		end

		local tier = WeightConfig.Get(session.record.zoneId)
		if tier == nil or not WeightConfig.IsSelectable(tier, requestedKg) then
			return false, "That weight is not available in this district."
		end

		local relevantStat = StatService:GetStat(player, session.definition.StatId)
		local requiredStat = WeightConfig.RequiredStat(tier, requestedKg)
		if relevantStat < requiredStat then
			return false,
				`Train {session.definition.StatId} to {NumberFormat.Format(requiredStat)} for {requestedKg} kg.`
		end

		-- A deliberate manual choice opts out of automation. The saved choice remains
		-- per district, so returning to this tier restores exactly what was selected.
		data.AutoLoadEnabled = false
		data.SelectedWeights[tier.ZoneId] = requestedKg
		session.weightKg = requestedKg
		-- A changed load begins a new visible rep. Restarting the authoritative clock
		-- prevents a nearly-finished light rep from paying as a heavy one.
		session.lastGainAt = os.clock()
		DataService:MarkDirty(player)
		self:_publishWeight(session)
		self:_push(player)
		return true, `Loaded {requestedKg} kg.`
	end)

	Net.BindFunction("SetAutoLoad", 4, function(player: Player, enabled: any)
		if type(enabled) ~= "boolean" then
			return false, "Invalid Auto Load setting."
		end
		if enabled and player:GetAttribute("AutoLoadOwned") ~= true then
			return false, "AUTOLOAD_PASS_REQUIRED"
		end

		if DataService:GetData(player) == nil then
			return false, "Your data is still loading."
		end

		self:SetAutoLoad(player, enabled)
		return true, if enabled then "Auto Load enabled." else "Auto Load disabled."
	end)
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
local function stationCopyFor(station: Instance, descendant: Instance): Instance?
	local current: Instance? = descendant
	while current ~= nil and current.Parent ~= station do
		current = current.Parent
	end
	return if current ~= station then current else nil
end

local function resolveExitCFrame(
	station: Instance,
	record: StationRecord,
	anchor: BasePart,
	anchorCFrame: CFrame
): CFrame
	-- Multi-bay stations keep one TrainExit beside each anchor. Prefer the exit in
	-- that same bay so three copies can be used simultaneously without everybody
	-- dismounting beside copy one.
	local copy = stationCopyFor(station, anchor)
	local localExit = if copy ~= nil then copy:FindFirstChild(EquipmentConfig.EXIT_NAME, true) else nil
	if localExit ~= nil and localExit:IsA("BasePart") then
		return localExit.CFrame
	end
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
	Raises an authored exit onto the actual surface beneath it.

	Exit markers are authored at ordinary ground height, but broad bases and tier mats
	can cover that X/Z after a machine is restyled. Pivoting the root to the old marker
	then leaves the feet inside the base. A downward ray makes the final standing height
	match whichever walkable surface is really there while preserving the marker's yaw.
]]
local function safeExitCFrame(
	station: Instance,
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	authored: CFrame
): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Ignore the invisible TrainExit marker itself and all machine geometry. The ray
	-- is looking for the court/ground the player can stand on, not the top of a bench.
	params.FilterDescendantsInstances = { character, station }
	params.IgnoreWater = true
	params.RespectCanCollide = true

	local origin = authored.Position + Vector3.new(0, 20, 0)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -60, 0), params)
	local y = authored.Position.Y
	if hit ~= nil then
		y = hit.Position.Y + humanoid.HipHeight + root.Size.Y / 2 + 0.15
	end

	local look = Vector3.new(authored.LookVector.X, 0, authored.LookVector.Z)
	if look.Magnitude < 0.1 then
		look = Vector3.zAxis
	end
	local position = Vector3.new(authored.Position.X, y, authored.Position.Z)
	return CFrame.lookAt(position, position + look.Unit)
end

--[[
	The combo multiplier a session has built up. Exposed so the HUD can show it.
]]
function TrainingService:GetComboMultiplier(player: Player): number
	local session = sessions[player]
	if session == nil then
		return 1
	end
	return if session.combo >= COMBO_GOAL then MAX_COMBO_MULTIPLIER else 1
end

function TrainingService:GetSession(player: Player): Session?
	return sessions[player]
end

function TrainingService:IsTraining(player: Player): boolean
	return sessions[player] ~= nil
end

--[[
	Live occupancy for every bound station, keyed by travel id, plus which station the
	asking player is on right now.

	The client cannot read this for itself. Station occupancy lives in attributes on
	the station model, and with StreamingEnabled most distant machine courts do not exist
	in a given client's Workspace — so "is the bench across the city free?" is a
	question only the server can answer.

	Returned as plain data rather than instances so the answer stays valid even if the
	station streams out the moment after it is sent.
]]
function TrainingService:GetSpotStatus(player: Player): { [string]: any }
	local status: { [string]: any } = {}

	for station, record in stations do
		local travelId = station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE)
		if type(travelId) ~= "string" then
			continue
		end

		local used = 0
		for _ in record.occupants do
			used += 1
		end

		status[travelId] = {
			Occupied = used,
			Capacity = #record.anchors,
			ZoneMultiplier = record.zoneMultiplier,
		}
	end

	local session = sessions[player]
	local currentId = if session ~= nil
		then session.station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE)
		else nil

	return {
		Spots = status,
		CurrentSpot = if type(currentId) == "string" then currentId else nil,
	}
end

function TrainingService:GetStaggerRemaining(player: Player): number
	local until_ = staggeredUntil[player]
	if until_ == nil then
		return 0
	end
	return math.max(0, until_ - os.clock())
end

local function buildState(player: Player, session: Session?): Types.TrainingState
	local data = DataService:GetData(player)
	local ownsAutoLoad = player:GetAttribute("AutoLoadOwned") == true
	local autoLoadEnabled = data ~= nil and data.AutoLoadEnabled and ownsAutoLoad

	if session == nil then
		return {
			StationId = nil,
			Combo = 0,
			StaggerSeconds = TrainingService:GetStaggerRemaining(player),
			ZoneId = nil,
			WeightKg = 0,
			MinWeightKg = 0,
			MaxWeightKg = 0,
			StepWeightKg = 0,
			RecommendedWeightKg = 0,
			WeightMultiplier = 1,
			RequiredStat = 0,
			AutoLoadEnabled = autoLoadEnabled,
			HasAutoLoad = ownsAutoLoad,
		}
	end

	local tier = WeightConfig.Get(session.record.zoneId)
	if tier == nil then
		error(`[TrainingService] No WeightConfig tier for zone "{session.record.zoneId}"`)
	end
	local recommended = WeightConfig.Recommended(tier, StatService:GetStat(player, session.definition.StatId))
	-- Stamped here rather than at the call site so what the client was told and what we
	-- think it was told cannot drift apart.
	session.lastRecommended = recommended
	return {
		StationId = session.definition.Id,
		Combo = session.combo,
		StaggerSeconds = TrainingService:GetStaggerRemaining(player),
		ZoneId = session.record.zoneId,
		WeightKg = session.weightKg,
		MinWeightKg = tier.MinKg,
		MaxWeightKg = tier.MaxKg,
		StepWeightKg = tier.StepKg,
		RecommendedWeightKg = recommended,
		WeightMultiplier = WeightConfig.GainMultiplier(tier, session.weightKg),
		RequiredStat = WeightConfig.RequiredStat(tier, session.weightKg),
		AutoLoadEnabled = autoLoadEnabled,
		HasAutoLoad = ownsAutoLoad,
	}
end

-- Replicated character attributes let every client render this lifter's physical
-- plates without trusting the owner's UI or changing the authoritative station.
--[[
	Turns Auto Load on or off and makes it take effect where the player is standing.

	Public because the remote is not the only caller: the Studio `/autoload` command
	flipped the same saved flag on its own and stopped there, so while seated it changed
	nothing you could see -- no reloaded bar, no push, a toggle that appeared dead. The
	ownership check stays with the remote, which is the only side that needs it.
]]
function TrainingService:SetAutoLoad(player: Player, enabled: boolean)
	local data = DataService:GetData(player)
	if data == nil then
		return
	end
	data.AutoLoadEnabled = enabled

	local session = sessions[player]
	if enabled and session ~= nil then
		local tier = WeightConfig.Get(session.record.zoneId)
		if tier ~= nil then
			session.weightKg =
				WeightConfig.Recommended(tier, StatService:GetStat(player, session.definition.StatId))
			-- A changed load begins a new visible rep, as a manual choice does.
			session.lastGainAt = os.clock()
			self:_publishWeight(session)
		end
	end

	DataService:MarkDirty(player)
	self:_push(player)
end

function TrainingService:_publishWeight(session: Session)
	local tier = WeightConfig.Get(session.record.zoneId)
	if tier == nil or session.character.Parent == nil then
		return
	end
	session.character:SetAttribute(WeightConfig.CHARACTER_WEIGHT_ATTRIBUTE, session.weightKg)
	session.character:SetAttribute(
		WeightConfig.CHARACTER_RATIO_ATTRIBUTE,
		WeightConfig.Ratio(tier, session.weightKg)
	)
	session.character:SetAttribute(PoseConfig.INTERVAL_ATTRIBUTE, effectiveRepInterval(session, tier))
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

	-- Each prompt belongs to one physical machine copy. The logical court contains
	-- three copies, but a player standing at one dumbbell rack must see that rack's
	-- capacity (1/1), not the court aggregate (3/3).
	for _, promptRecord in record.prompts do
		local copyUsed = 0
		for _, anchorIndex in promptRecord.anchorIndices do
			local occupant = record.occupants[anchorIndex]
			if occupant ~= nil and occupant.Parent ~= nil then
				copyUsed += 1
			end
		end
		local copyCapacity = #promptRecord.anchorIndices
		promptRecord.copy:SetAttribute(EquipmentConfig.OCCUPANCY_ATTRIBUTE, copyUsed)
		promptRecord.copy:SetAttribute(EquipmentConfig.CAPACITY_ATTRIBUTE, copyCapacity)
		promptRecord.prompt.ObjectText =
			`{record.definition.DisplayName} ({copyCapacity - copyUsed}/{copyCapacity} free)`
	end
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

-- A future machine-specific requirement follows its own muscle, just like districts.
function TrainingService:_isUnlocked(player: Player, definition: EquipmentConfig.EquipmentDefinition): boolean
	if StatService:GetStat(player, definition.StatId) >= definition.UnlockPower then
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
		exitCFrame = resolveExitCFrame(station, record, anchor, anchorCFrame),
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
		lastGainAt = os.clock(),
		weightKg = 0,
		-- Nothing has been sent yet, and no real recommendation is negative, so the
		-- first push always counts as a change.
		lastRecommended = -1,
	}

	local tier = WeightConfig.Get(record.zoneId)
	if tier == nil then
		error(`[TrainingService] No WeightConfig tier for zone "{record.zoneId}"`)
	end
	local data = DataService:GetData(player)
	local recommended = WeightConfig.Recommended(tier, StatService:GetStat(player, definition.StatId))
	local saved = if data ~= nil then data.SelectedWeights[tier.ZoneId] else nil
	local selected = if type(saved) == "number" then WeightConfig.Snap(tier, saved) else tier.MinKg
	selected = math.min(selected, recommended)
	if data ~= nil and data.AutoLoadEnabled and player:GetAttribute("AutoLoadOwned") == true then
		selected = recommended
	end
	session.weightKg = selected

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

	-- Publish the effective interval before the pose id. Attribute replication can
	-- arrive a frame apart; this ordering prevents a client from beginning the pose
	-- at the fallback one-second tempo and then restarting it immediately.
	session.lastGainAt = os.clock()
	self:_publishWeight(session)

	-- Every client animates every training player it can see, so which pose to run
	-- travels as a character attribute rather than a remote to one owner.
	character:SetAttribute(MuscleDefinitionConfig.TRAINING_ATTRIBUTE, definition.StatId)
	character:SetAttribute(PoseConfig.POSE_ATTRIBUTE, definition.PoseId)

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
		character:SetAttribute(MuscleDefinitionConfig.TRAINING_ATTRIBUTE, nil)
		character:SetAttribute(PoseConfig.POSE_ATTRIBUTE, nil)
		character:SetAttribute(PoseConfig.INTERVAL_ATTRIBUTE, nil)
		character:SetAttribute(WeightConfig.CHARACTER_WEIGHT_ATTRIBUTE, nil)
		character:SetAttribute(WeightConfig.CHARACTER_RATIO_ATTRIBUTE, nil)

		-- Clearing this is what sends the weights back to their rack.
		local anchorValue = character:FindFirstChild(EquipmentConfig.ANCHOR_VALUE_NAME)
		if anchorValue ~= nil then
			anchorValue:Destroy()
		end
	end

	local root = session.root

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
		character:PivotTo(safeExitCFrame(session.station, character, humanoid, root, session.exitCFrame))
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end

	-- Keep the assembly anchored until after the safe pivot. Releasing it inside the
	-- machine for even one physics step let some benches/walls wedge the root before
	-- the exit teleport landed. Explicitly returning to Running also clears a stale
	-- physics state left by an anchored exercise rig.
	if root.Parent ~= nil then
		root.Anchored = false
	end
	if moveToExit and humanoid.Parent ~= nil and humanoid.Health > 0 then
		humanoid:ChangeState(Enum.HumanoidStateType.Running)
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

	Each physical copy has a prompt. Any prompt on the court is both "get on" and
	"get off": triggering the court you are already using leaves it, which is why
	the player never has to find a second key.
]]
function TrainingService:_onTriggered(player: Player, station: Instance, requestedAnchorIndices: { number }?)
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

	-- The district gate. It used to be geometry: a ZoneGate slab you could not walk
	-- through without the power, which also meant a machine could not be reached
	-- without passing one. Travel is a menu button now and two of the gyms stand on
	-- Downtown's own streets, so nothing physical stops a fresh player strolling into
	-- Iron Hall and training at its multiplier. Gain already rides on the zone; this
	-- is the same rule applied to getting on the machine at all.
	local districtShortfall = record.zoneRequiredStat - StatService:GetStat(player, definition.StatId)
	if districtShortfall > 0 then
		Net.Event("Notify"):FireClient(
			player,
			`{record.zoneName or "This district"} needs {NumberFormat.Format(districtShortfall)} more {definition.StatId}`
		)
		return
	end

	if not self:_isUnlocked(player, definition) then
		Net.Event("Notify"):FireClient(
			player,
			`{definition.DisplayName} needs {NumberFormat.Format(definition.UnlockPower)} power`
		)
		return
	end

	local anchorIndex: number? = nil
	if requestedAnchorIndices ~= nil then
		for _, candidateIndex in requestedAnchorIndices do
			local occupant = record.occupants[candidateIndex]
			if occupant == nil or occupant.Parent == nil then
				anchorIndex = candidateIndex
				break
			end
		end
	else
		anchorIndex = findFreeAnchor(record)
	end
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
	Net.Event("Notify")
		:FireClient(player, `Training on {definition.DisplayName} — press Space or hold E to stop`)
end

--[[
	Binds a tagged station: reads its definition, finds its spots, and gives it the
	prompt players hold E on. Misconfigured models are reported and skipped, never
	fatal — one bad machine should not take the gym down.
]]
--[[
	Re-checks a bound station's tier and corrects it if it has changed.

	Binding used to be once and for all: `_bindStation` returns early for anything
	already in `stations`, and nothing ever ran `AtPosition` again. That is fine when
	the zone volumes are already tagged, and wrong when they are not — CollectionService
	tags and instance replication arrive in no guaranteed order at startup, so a station
	that bound a moment too early froze at the wrong multiplier, or at x1, for the life
	of the server. Nothing downstream could recover: the attribute written here is the
	only zone factor in both the payout and the billboard.
]]
function TrainingService:_refreshStationZone(station: Instance)
	local record = stations[station]
	if record == nil then
		return
	end

	local point = if station:IsA("Model")
		then station:GetPivot().Position
		else (EquipmentConfig.GetBase(station) :: BasePart).Position
	local zone = ZoneConfig.AtPosition(point)
	local multiplier = if zone ~= nil then zone.GainMultiplier else 1
	if multiplier == record.zoneMultiplier then
		return
	end

	local zoneId = if zone ~= nil then zone.Id else "Garage"
	local weightTier = WeightConfig.Get(zoneId)
	record.zoneMultiplier = multiplier
	record.zoneId = zoneId
	record.zoneName = if zone ~= nil then zone.DisplayName else nil
	record.zoneRequiredStat = if weightTier ~= nil then weightTier.RequiredStat else 0
	station:SetAttribute("GainMultiplier", multiplier)
	station:SetAttribute("RequiredStat", record.zoneRequiredStat)
end

function TrainingService:_bindStation(station: Instance)
	if stations[station] ~= nil then
		-- Already bound, but its tier may have been resolved before the zone volumes
		-- were tagged. Cheap to re-check, and it is the only chance to self-correct.
		self:_refreshStationZone(station)
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

	-- Group every authored anchor beneath its top-level physical copy. Every generated
	-- copy now owns exactly one anchor, so each prompt advertises and enforces 1/1.
	local copyOrder: { Instance } = {}
	local indicesByCopy: { [Instance]: { number } } = {}
	for anchorIndex, anchor in anchors do
		local copy = stationCopyFor(station, anchor) or station
		local indices = indicesByCopy[copy]
		if indices == nil then
			indices = {}
			indicesByCopy[copy] = indices
			table.insert(copyOrder, copy)
		end
		table.insert(indices, anchorIndex)
	end

	local prompts: { PromptRecord } = {}
	for _, copy in copyOrder do
		local localBase = copy:FindFirstChild(EquipmentConfig.BASE_NAME, true)
		local promptBase = if localBase ~= nil and localBase:IsA("BasePart") then localBase else base
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "TrainPrompt"
		prompt.ActionText = definition.ActionText
		prompt.ObjectText = definition.DisplayName
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
		prompt.HoldDuration = EquipmentConfig.PROMPT_HOLD_SECONDS
		prompt.MaxActivationDistance = EquipmentConfig.PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Parent = promptBase
		local requestedAnchorIndices = indicesByCopy[copy]
		prompt.Triggered:Connect(function(player: Player)
			self:_onTriggered(player, station, requestedAnchorIndices)
		end)
		table.insert(prompts, {
			prompt = prompt,
			copy = copy,
			anchorIndices = requestedAnchorIndices,
		})
	end

	-- A machine is worth whatever tier it stands in. Resolving by containment rather
	-- than by an attribute means a designer tiers a machine by placing it, and cannot
	-- leave a bench in Titan Forge still paying Garage rates.
	--
	-- Sample the middle of the station, not `base`. A three-copy station has no direct
	-- child named "Base", so GetBase falls through to the first BasePart it can find,
	-- which is inside the westernmost copy -- about 34 studs off centre against a zone
	-- half-extent of 56. That works today with 22 studs to spare and would flip a whole
	-- station into the neighbouring tier the moment a court moved or the copies spread.
	local samplePoint = base.Position
	if station:IsA("Model") then
		samplePoint = station:GetPivot().Position
	end
	local zone = ZoneConfig.AtPosition(samplePoint)
	if zone == nil then
		warn(
			`[TrainingService] {station:GetFullName()} stands outside every "{ZoneConfig.ZONE_TAG}" `
				.. `volume, so it uses the x1 equipment bonus. Put it inside one to tier it.`
		)
	end
	local zoneId = if zone ~= nil then zone.Id else "Garage"
	local weightTier = WeightConfig.Get(zoneId)

	local record: StationRecord = {
		definition = definition,
		zoneMultiplier = if zone ~= nil then zone.GainMultiplier else 1,
		zoneRequiredStat = if weightTier ~= nil then weightTier.RequiredStat else 0,
		zoneId = zoneId,
		zoneName = if zone ~= nil then zone.DisplayName else nil,
		anchors = anchors,
		exit = if exit ~= nil and exit:IsA("BasePart") then exit else nil,
		prompts = prompts,
		occupants = {},
	}
	stations[station] = record
	-- Replicate the resolved rate to streamed clients. The zone volume is server-only
	-- knowledge at long range, while billboards must say +1/s through +64/s honestly.
	station:SetAttribute("GainMultiplier", record.zoneMultiplier)
	station:SetAttribute("RequiredStat", record.zoneRequiredStat)
	if weightTier ~= nil then
		station:SetAttribute("MinWeightKg", weightTier.MinKg)
		station:SetAttribute("MaxWeightKg", weightTier.MaxKg)
		station:SetAttribute("StepWeightKg", weightTier.StepKg)
	end

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

	for _, promptRecord in record.prompts do
		promptRecord.prompt:Destroy()
	end
	stations[station] = nil
end

--[[
	One completed visible rep for one mounted player.

	The server, procedural pose, moving machine stack, popup and rep sound all use the
	same effective interval. Slower exercises therefore pay a larger amount less often
	while keeping the advertised per-second progression exactly unchanged.
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

	local tier = WeightConfig.Get(session.record.zoneId)
	if tier == nil then
		self:_dismount(player, false)
		return
	end
	local repSeconds = effectiveRepInterval(session, tier)
	if now - session.lastGainAt < repSeconds then
		return
	end

	-- Advance by the authored duration rather than snapping the clock to this
	-- Heartbeat. Snapping would add up a few milliseconds of frame lateness every
	-- cycle until the popup visibly drifted away from the motion. If the server ever
	-- stalls for an entire extra rep, discard that missed cycle instead of bursting
	-- several rewards at the player on consecutive frames.
	session.lastGainAt += repSeconds
	if now - session.lastGainAt >= repSeconds then
		session.lastGainAt = now
	end
	session.combo += 1
	local completedWeightKg = session.weightKg
	local data = DataService:GetData(player)

	-- Cheap insurance that nothing has nudged the player off their spot. Writing an
	-- identical CFrame is a no-op, so this costs no replication in the normal case.
	session.root.CFrame = session.anchorCFrame

	local equipmentPerSecond = session.definition.BaseGain / session.definition.RepInterval
	local comboMultiplier = self:GetComboMultiplier(player)
	local relevantBefore = StatService:GetStat(player, session.definition.StatId)
	local gain = Formulas.MachineTrainingRate(equipmentPerSecond, session.record.zoneMultiplier)
		* repSeconds
		* comboMultiplier
		* WeightConfig.GainMultiplier(tier, completedWeightKg)
	local gained = StatService:AddStat(player, session.definition.StatId, gain)
	if gained > 0 then
		local nextTier = WeightConfig.Next(tier.ZoneId)
		if
			nextTier ~= nil
			and relevantBefore < tier.MaxRequiredStat
			and relevantBefore + gained >= tier.MaxRequiredStat
		then
			local nextZone = ZoneConfig.Get(nextTier.ZoneId)
			Net.Event("Notify"):FireClient(
				player,
				`{if nextZone ~= nil then nextZone.DisplayName else nextTier.ZoneId} unlocked for {session.definition.StatId}!`
			)
		end
		local payload: Types.TrainingGain = {
			StatId = session.definition.StatId,
			Amount = gained,
			PerSecond = gained / repSeconds,
			Combo = math.min(session.combo, COMBO_GOAL),
			ComboGoal = COMBO_GOAL,
			ComboMultiplier = comboMultiplier,
		}
		Net.Event("TrainingGain"):FireClient(player, payload)
	end

	-- Auto Load advances only after the completed rep has been paid at its original
	-- load. The new load and its slower tempo begin together on the next cycle.
	if data ~= nil and data.AutoLoadEnabled and player:GetAttribute("AutoLoadOwned") == true then
		local recommended =
			WeightConfig.Recommended(tier, StatService:GetStat(player, session.definition.StatId))
		if recommended ~= session.weightKg then
			session.weightKg = recommended
			session.lastGainAt = now
			self:_publishWeight(session)
		end
	end

	if now - (lastPushAt[player] or 0) >= PUSH_INTERVAL then
		self:_push(player)
	end
end

function TrainingService:Start()
	-- Client can request to stop training by pressing Space or jumping.
	Net.BindEvent("StopTraining", 4, function(player: Player)
		self:Stop(player)
	end)

	--[[
		A stat that grows past a gate unlocks a heavier plate, and the panel has to hear
		about it. Without this the load selector kept whatever recommendation its last
		push carried: a dev command, or any jump in a stat between reps, left every row
		above the stale figure drawn as locked, and the only way to refresh was to load
		a different weight — which is the long way round to say the panel lied.

		Only a real change in the recommendation is worth a push. Stats move on every
		rep and `_step` already pushes on its own cadence; this is for the moments when
		the answer to "what can I load?" actually changed.
	]]
	StatService.StatChanged:Connect(function(player: Player, statId: string)
		local session = sessions[player]
		if session == nil or session.definition.StatId ~= statId then
			return
		end
		local tier = WeightConfig.Get(session.record.zoneId)
		if tier == nil then
			return
		end
		if WeightConfig.Recommended(tier, StatService:GetStat(player, statId)) ~= session.lastRecommended then
			self:_push(player)
		end
	end)

	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		self:_bindStation(station)
	end

	CollectionService:GetInstanceAddedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_bindStation(station)
	end)

	CollectionService:GetInstanceRemovedSignal(EquipmentConfig.STATION_TAG):Connect(function(station)
		self:_unbindStation(station)
	end)

	-- One sweep once the world has settled, to catch any station that resolved its tier
	-- before the zone volumes were tagged. Stations and "GymZone" volumes are tagged
	-- independently and in no guaranteed order, so the loop above can genuinely run
	-- first; without this a machine stays at the wrong multiplier -- or at x1 -- for the
	-- life of the server, and the only symptom is a billboard quietly reading the
	-- previous tier's rate.
	task.delay(5, function()
		for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
			self:_refreshStationZone(station)
		end
	end)

	local function watchPlayer(player: Player)
		-- A newly purchased Auto Load pass is granted by setting this server attribute.
		-- Refresh immediately so the open load panel becomes a toggle without making
		-- the player dismount or rejoin.
		player:GetAttributeChangedSignal("AutoLoadOwned"):Connect(function()
			self:_push(player)
		end)

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
	end

	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	Players.PlayerAdded:Connect(watchPlayer)

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
