--!strict
--[[
	TravelService — moving to specific training locations.

	This replaces the touch gates. Gates were force-field slabs on the hub rim: you
	walked into one and it threw you at a tier. That worked when the map was eleven
	decks around a plaza, but a city with two of its gyms standing on its own streets
	has nowhere sensible to put a wall, and walking back to the hub to change district
	is not a mechanic, it is a commute.

	The connected-city map exposes every individual training station. Travel is a
	button on that map screen, and the rules that used to live in
	geometry live here instead:

	  * **Power.** Same check the gates made. A district you cannot afford is listed
	    and priced, not hidden — knowing what is out there is most of why you grind.
	  * **Where from.** Free travel only from inside a `SafeZone`, which in practice
	    means the plaza. Fast Travel lifts that. Selling *convenience* rather than
	    progress is the line this game draws everywhere else, and it holds here.
	  * **Not mid-fight.** Reusing FlightService's combat lock, because escaping a
	    losing fight by opening a menu would undo the whole PvP hook. The victim of
	    a hit is grounded already; travel just refuses on the same window.

	Server-authoritative for the same reason it always was: a client that could place
	its own character would skip every one of those rules.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Modules.Loader)
local Net = require(ReplicatedStorage.Modules.Net)
local NumberFormat = require(ReplicatedStorage.Modules.NumberFormat)
local EquipmentConfig = require(ReplicatedStorage.Modules.EquipmentConfig)
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)
local Signal = require(ReplicatedStorage.Packages.Signal)

-- Long enough that travel is a decision rather than a way to flicker around the
-- map, short enough that a mistaken destination is not a punishment.
local TRAVEL_COOLDOWN = 4
-- The gamepass that allows teleporting at all. Without it there is no fast travel
-- from anywhere, including the plaza: a non-owner who picks a destination is given a
-- tracked waypoint and walks or flies there.
--
-- It is stubbed at AssetId 0 until it exists in the dashboard, and HasFastTravel
-- returns false for that — so today nobody teleports and everybody tracks. That is the
-- correct behaviour for the state the product is in, not a bug.
local FAST_TRAVEL_PRODUCT = "FastTravel"
-- How long to wait for the destination to stream in before going anyway.
local STREAM_WAIT = 1
local MAP_FEATURE_TAG = "MapFeature"

local TravelService = {
	Name = "TravelService",
	Priority = 17,
}

--- (player, zoneId, travelId) — fired after a successful arrival.
TravelService.Traveled = Signal.new()

-- Studio-only Fast Travel grant, set by DevService. Never populated on a live server:
-- DevService itself refuses to run outside Studio, so nothing can reach this.
local studioOverride: { [Player]: boolean } = {}

local StatService: any = nil
local TrainingService: any = nil
local PurchaseService: any = nil
local FlightService: any = nil

local nextTravelAt: { [Player]: number } = {}

local function findStation(travelId: string): Instance?
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		if station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE) == travelId then
			return station
		end
	end
	return nil
end

local function stationZone(station: Instance): ZoneConfig.Zone?
	local base = EquipmentConfig.GetBase(station)
	return if base ~= nil then ZoneConfig.AtPosition(base.Position) else nil
end

-- A TrainExit is already authored at HumanoidRootPart height and orientation.
-- Falling back to the Base keeps hand-placed stations usable on the map too.
local function landingCFrame(station: Instance): CFrame?
	local exit = station:FindFirstChild(EquipmentConfig.EXIT_NAME, true)
	if exit ~= nil and exit:IsA("BasePart") then
		return exit.CFrame
	end
	local base = EquipmentConfig.GetBase(station)
	if base == nil then
		return nil
	end
	return base.CFrame + Vector3.new(0, base.Size.Y / 2 + 4, 0)
end

function TravelService:Init()
	StatService = Loader.Get("StatService")
	TrainingService = Loader.Get("TrainingService")
	PurchaseService = Loader.Get("PurchaseService")
	FlightService = Loader.Get("FlightService")

	Net.BindFunction("Travel", 2, function(player: Player, zoneId: any)
		if type(zoneId) ~= "string" then
			return false, "Unknown destination."
		end
		return self:Travel(player, zoneId)
	end)

	Net.BindFunction("GetDestinations", 2, function(_player: Player)
		return self:GetDestinations(), self:GetMapFeatures()
	end)

	-- The client needs to know whether a destination button says "Go" or "Track"
	-- before it is pressed. Ownership itself is still only ever decided here.
	Net.BindFunction("GetTravelAccess", 2, function(player: Player)
		return { HasFastTravel = self:CanTravelFrom(player) }
	end)
end

function TravelService:CanEnter(player: Player, requiredPower: number): boolean
	return StatService:GetTotalPower(player) >= requiredPower
end

--[[
	Whether the player owns the pass that lets them travel from anywhere.
]]
--[[
	Studio-only: pretend this player owns the pass. Called by DevService, which cannot
	run outside Studio, so a live server has no path to it.
]]
function TravelService:SetStudioFastTravel(player: Player, enabled: boolean)
	if enabled then
		studioOverride[player] = true
	else
		studioOverride[player] = nil
	end
end

function TravelService:HasFastTravel(player: Player): boolean
	local product = PurchaseService:GetProduct(FAST_TRAVEL_PRODUCT)
	if product == nil or product.AssetId == 0 then
		return false
	end
	return PurchaseService:OwnsGamepass(player, product.AssetId)
end

--[[
	Whether the player may teleport at all.

	This used to be "from inside a safe zone, or with the pass". It is now the pass
	alone. The plaza rule meant the fastest way across the city was to die or walk back
	to spawn first, which taught players to treat the hub as a loading screen — and it
	made the pass worth very little, since the free path did the same job with one extra
	step.

	A non-owner is not blocked from the destination, only from skipping the trip: the
	client turns a refused Travel into a tracked waypoint. Flight is available from
	spawn, so every location is reachable on foot or in the air.
]]
function TravelService:CanTravelFrom(player: Player): boolean
	if studioOverride[player] then
		return true
	end
	return self:HasFastTravel(player)
end

-- Every map-enabled station in world space. The server supplies this because
-- streaming means most of the connected city is absent from a spawn client's Workspace.
function TravelService:GetDestinations(): { any }
	local out = {}

	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		local travelId = station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE)
		local definition = EquipmentConfig.Resolve(station)
		local zone = stationZone(station)
		local landing = landingCFrame(station)
		if type(travelId) ~= "string" or definition == nil or zone == nil or landing == nil then
			continue
		end
		local accessKind = station:GetAttribute("AccessKind")
		local floorIndex = station:GetAttribute("FloorIndex")
		local environmentId = station:GetAttribute("EnvironmentId")
		local variantId = station:GetAttribute("VariantId")
		local exerciseFamily = station:GetAttribute("ExerciseFamily")
		local requiresFlight = station:GetAttribute("RequiresFlight")
		table.insert(out, {
			Id = travelId,
			ZoneId = zone.Id,
			EquipmentId = definition.Id,
			StatId = definition.StatId,
			RequiredPower = math.max(zone.RequiredPower, definition.UnlockPower),
			GainMultiplier = zone.GainMultiplier,
			X = landing.Position.X,
			Y = landing.Position.Y,
			Z = landing.Position.Z,
			AccessKind = if type(accessKind) == "string" then accessKind else "Street",
			FloorIndex = if type(floorIndex) == "number" then floorIndex else 1,
			EnvironmentId = if type(environmentId) == "string" then environmentId else "Unknown",
			VariantId = if type(variantId) == "string" then variantId else definition.Id,
			ExerciseFamily = if type(exerciseFamily) == "string" then exerciseFamily else definition.StatId,
			RequiresFlight = requiresFlight == true,
		})
	end
	table.sort(out, function(a, b)
		if a.RequiredPower ~= b.RequiredPower then
			return a.RequiredPower < b.RequiredPower
		end
		if a.StatId ~= b.StatId then
			return a.StatId < b.StatId
		end
		return a.Id < b.Id
	end)

	return out
end

-- A streaming-proof top-down description of the real city. The generated world
-- tags its land, roads, blocks, buildings, parks, plaza and safe-zone footprint;
-- the server serialises those parts because a spawn client cannot see distant
-- Workspace geometry yet. Returning primitive values keeps this response stable
-- even if the physical parts stream out immediately after the request.
function TravelService:GetMapFeatures(): { any }
	local out = {}

	for _, instance in CollectionService:GetTagged(MAP_FEATURE_TAG) do
		if not instance:IsA("BasePart") then
			continue
		end
		local kind = instance:GetAttribute("MapKind")
		local shape = instance:GetAttribute("MapShape")
		if type(kind) ~= "string" or type(shape) ~= "string" then
			continue
		end
		local _, yaw, _ = instance.CFrame:ToOrientation()
		table.insert(out, {
			Kind = kind,
			Shape = shape,
			X = instance.Position.X,
			Z = instance.Position.Z,
			Width = instance.Size.X,
			Depth = instance.Size.Z,
			Rotation = math.deg(yaw),
			Color = instance.Color,
		})
	end

	table.sort(out, function(a, b)
		if a.Kind ~= b.Kind then
			return a.Kind < b.Kind
		end
		if a.X ~= b.X then
			return a.X < b.X
		end
		if a.Z ~= b.Z then
			return a.Z < b.Z
		end
		return a.Width < b.Width
	end)

	return out
end

--[[
	Moves a player to a district, or says why not.

	Returns (ok, message) — the house shape for a client-facing request, and the
	message is shown to the player verbatim, so every refusal has to read as an
	explanation rather than as an error.
]]
function TravelService:Travel(player: Player, travelId: string): (boolean, string)
	local station = findStation(travelId)
	if station == nil then
		return false, "Unknown destination."
	end
	local definition = EquipmentConfig.Resolve(station)
	local zone = stationZone(station)
	local landing = landingCFrame(station)
	if definition == nil or zone == nil or landing == nil then
		return false, "That training location is unavailable."
	end
	local requiredPower = math.max(zone.RequiredPower, definition.UnlockPower)

	local now = os.clock()
	if now < (nextTravelAt[player] or 0) then
		return false, "Catch your breath first."
	end

	local character = player.Character
	local humanoid = if character ~= nil then character:FindFirstChildOfClass("Humanoid") else nil
	if character == nil or humanoid == nil or humanoid.Health <= 0 then
		return false, "You are in no state to travel."
	end

	-- The combat lock. FlightService grounds anyone who takes a hit; travelling
	-- out of a fight is the same escape as flying out of one.
	if FlightService:IsGrounded(player) then
		return false, "Not while you are being hit."
	end

	if not self:CanTravelFrom(player) then
		-- The client turns this exact refusal into a tracked waypoint, so the message
		-- explains the offer rather than just denying it.
		return false, "NO_FAST_TRAVEL"
	end

	if not self:CanEnter(player, requiredPower) then
		local needed = requiredPower - StatService:GetTotalPower(player)
		return false, `{definition.DisplayName} needs {NumberFormat.Format(needed)} more power.`
	end

	-- Leave the machine first. Pivoting a player whose root is anchored to a
	-- TrainAnchor would strand them mid-air and leave the station reading as
	-- occupied for as long as they stayed away.
	if TrainingService:IsTraining(player) then
		TrainingService:Stop(player)
	end

	nextTravelAt[player] = now + TRAVEL_COOLDOWN

	-- Load the destination before dropping anyone into it. Travel crosses up to
	-- 1,500 studs, far outside StreamingTargetRadius, so the arrival point is a
	-- region the client has never seen — and a character placed on ground that does
	-- not exist yet falls through it.
	--
	-- This yields, which is why the timeout is short: a second of "travelling" is
	-- fine, and Workspace.StreamingIntegrityMode holds the client if the ground is
	-- still not there. Wrapped because it throws if the player leaves mid-wait, and
	-- somebody disconnecting should not error a remote handler.
	pcall(function()
		player:RequestStreamAroundAsync(landing.Position, STREAM_WAIT)
	end)
	character:PivotTo(landing)

	TravelService.Traveled:Fire(player, zone.Id, travelId)

	return true, `Travelled to {zone.DisplayName} {definition.DisplayName}.`
end

function TravelService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		nextTravelAt[player] = nil
	end)

	local seen: { [string]: boolean } = {}
	for _, station in CollectionService:GetTagged(EquipmentConfig.STATION_TAG) do
		local travelId = station:GetAttribute(EquipmentConfig.TRAVEL_ATTRIBUTE)
		if travelId == nil then
			continue
		end
		if type(travelId) ~= "string" or travelId == "" then
			warn(`[TravelService] {station:GetFullName()} has an invalid travel id`)
		elseif seen[travelId] then
			warn(`[TravelService] Duplicate travel id "{travelId}"`)
		else
			seen[travelId] = true
		end
	end
end

return TravelService
