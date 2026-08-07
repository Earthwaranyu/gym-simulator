--!strict
--[[
	TravelService — moving between districts.

	This replaces the touch gates. Gates were force-field slabs on the hub rim: you
	walked into one and it threw you at a tier. That worked when the map was eleven
	decks around a plaza, but a city with two of its gyms standing on its own streets
	has nowhere sensible to put a wall, and walking back to the hub to change district
	is not a mechanic, it is a commute.

	So travel is a button on the map screen, and the rules that used to live in
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
local ZoneConfig = require(ReplicatedStorage.Modules.ZoneConfig)

-- Long enough that travel is a decision rather than a way to flicker around the
-- map, short enough that a mistaken destination is not a punishment.
local TRAVEL_COOLDOWN = 4
-- The gamepass that lifts the "only from the plaza" rule. Absent until #74 adds
-- the product file, and stubbed at AssetId 0 until it exists in the dashboard —
-- HasFastTravel returns false for both, so the plaza rule simply holds.
local FAST_TRAVEL_PRODUCT = "FastTravel"
-- Studs above the pad to land on, so a character arrives standing rather than
-- intersecting it.
local LANDING_CLEARANCE = 4

local TravelService = {
	Name = "TravelService",
	Priority = 17,
}

local StatService: any = nil
local CombatService: any = nil
local TrainingService: any = nil
local PurchaseService: any = nil
local FlightService: any = nil

local nextTravelAt: { [Player]: number } = {}

--[[
	The pad a district lands arrivals on, or nil if nobody built one.
]]
local function findSpawn(zoneId: string): BasePart?
	for _, pad in CollectionService:GetTagged(ZoneConfig.SPAWN_TAG) do
		if pad:IsA("BasePart") and pad:GetAttribute(ZoneConfig.ZONE_ATTRIBUTE) == zoneId then
			return pad
		end
	end
	return nil
end

function TravelService:Init()
	StatService = Loader.Get("StatService")
	CombatService = Loader.Get("CombatService")
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
		return self:GetDestinations()
	end)
end

--[[
	Whether a player meets a district's power requirement.
]]
function TravelService:CanEnter(player: Player, zone: ZoneConfig.Zone): boolean
	return StatService:GetTotalPower(player) >= zone.RequiredPower
end

--[[
	Whether the player owns the pass that lets them travel from anywhere.
]]
function TravelService:HasFastTravel(player: Player): boolean
	local product = PurchaseService:GetProduct(FAST_TRAVEL_PRODUCT)
	if product == nil or product.AssetId == 0 then
		return false
	end
	return PurchaseService:OwnsGamepass(player, product.AssetId)
end

--[[
	Whether the player is somewhere travel is allowed from.

	Reuses CombatService's safe-zone test rather than naming the plaza, so if a
	second safe volume is ever added it is travellable for the same reason it is
	safe: nobody can be jumped standing in it, so nothing is being escaped.
]]
function TravelService:CanTravelFrom(player: Player): boolean
	return CombatService:IsInSafeZone(player) or self:HasFastTravel(player)
end

--[[
	Every district's landing pad in world space.

	The client cannot read these off Workspace itself. StreamingEnabled means a
	district 1,500 studs away is not replicated to a player standing in the plaza,
	so its pad does not exist client-side to be measured — the travel map would
	draw whatever happened to be loaded. The server always has all of them.
]]
function TravelService:GetDestinations(): { any }
	local out = {}

	for _, zone in ZoneConfig.List do
		local pad = findSpawn(zone.Id)
		if pad == nil then
			continue
		end
		table.insert(out, {
			Id = zone.Id,
			X = pad.Position.X,
			Y = pad.Position.Y,
			Z = pad.Position.Z,
		})
	end

	return out
end

--[[
	Moves a player to a district, or says why not.

	Returns (ok, message) — the house shape for a client-facing request, and the
	message is shown to the player verbatim, so every refusal has to read as an
	explanation rather than as an error.
]]
function TravelService:Travel(player: Player, zoneId: string): (boolean, string)
	local zone = ZoneConfig.Get(zoneId)
	if zone == nil then
		return false, "Unknown destination."
	end

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
		return false, "Travel from the spawn plaza, or get Fast Travel to go from anywhere."
	end

	if not self:CanEnter(player, zone) then
		local needed = zone.RequiredPower - StatService:GetTotalPower(player)
		return false, `{zone.DisplayName} needs {NumberFormat.Format(needed)} more power.`
	end

	local pad = findSpawn(zone.Id)
	if pad == nil then
		warn(`[TravelService] "{zone.Id}" has no part tagged "{ZoneConfig.SPAWN_TAG}"`)
		return false, `{zone.DisplayName} has nowhere to land.`
	end

	-- Leave the machine first. Pivoting a player whose root is anchored to a
	-- TrainAnchor would strand them mid-air and leave the station reading as
	-- occupied for as long as they stayed away.
	if TrainingService:IsTraining(player) then
		TrainingService:Stop(player)
	end

	nextTravelAt[player] = now + TRAVEL_COOLDOWN
	character:PivotTo(pad.CFrame + Vector3.new(0, pad.Size.Y / 2 + LANDING_CLEARANCE, 0))

	return true, `Welcome to {zone.DisplayName}.`
end

function TravelService:Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		nextTravelAt[player] = nil
	end)

	-- A district with no pad is a destination the map will offer and travel will
	-- then refuse, so say so at boot rather than at the moment a player tries it.
	for _, zone in ZoneConfig.List do
		if findSpawn(zone.Id) == nil then
			warn(`[TravelService] "{zone.Id}" has no "{ZoneConfig.SPAWN_TAG}" pad; travel there will fail`)
		end
	end
end

return TravelService
