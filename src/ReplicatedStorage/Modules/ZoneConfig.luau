--!strict
--[[
	ZoneConfig — training multiplier tiers and what it takes to use them.

	A zone is a tagged volume around one hidden training location; this table says what
	each tier is called and how much power it demands. The connected city can place one
	volume for each stat at every tier without changing the systems that consume it.

	Zones do double duty: TokenService only accrues inside one, so the same volumes that
	gate progression also define where idling pays. That is deliberate — it keeps
	players in built areas where other players can find them.
]]

local CollectionService = game:GetService("CollectionService")

export type Zone = {
	Id: string,
	DisplayName: string,
	-- One line of flavour, shown beside a selected training location on the map.
	Tagline: string,
	-- Total power needed to use a location carrying this tier.
	RequiredPower: number,
	-- Everything trained inside this zone is multiplied by this.
	--
	-- Tier lives on the zone rather than on the equipment, so one "Bench Press" entry
	-- covers every bench in the game and a new tier is one row plus tagged volumes.
	-- The alternative — an EquipmentConfig entry per machine per tier — is fifty-odd
	-- near-identical rows that all have to move together whenever a number changes.
	GainMultiplier: number,
	Color: Color3,
}

-- Tag on the volume a player stands in.
--
-- This must be a genuine VOLUME the player's HumanoidRootPart ends up inside, not the
-- floor they walk on. Tagging a 1-stud floor slab looks right and silently breaks all
-- token accrual: a standing player's root sits several studs above it, so the
-- containment test never passes. Zone volumes are invisible, tall, and cover the whole
-- playable height of their area.
local ZONE_TAG = "GymZone"
-- Tag on the pad travel lands you on.
local SPAWN_TAG = "ZoneSpawn"
-- Attribute naming which zone a tagged part belongs to.
local ZONE_ATTRIBUTE = "ZoneId"

-- The seven active training tiers double exactly: x1 through x64. The remaining rows
-- stay in the catalog as dormant future expansion themes, but the generated world does
-- not place their GymZones.
local zones: { Zone } = {
	{
		Id = "Garage",
		DisplayName = "Garage Gym",
		Tagline = "Where everybody starts.",
		RequiredPower = 0,
		GainMultiplier = 1,
		Color = Color3.fromRGB(126, 211, 155),
	},
	{
		Id = "Iron",
		DisplayName = "Iron Hall",
		Tagline = "Warehouse iron, two streets off the plaza.",
		RequiredPower = 500,
		GainMultiplier = 2,
		Color = Color3.fromRGB(66, 165, 245),
	},
	{
		Id = "Powerhouse",
		DisplayName = "The Powerhouse",
		Tagline = "The docks work all night.",
		RequiredPower = 5e3,
		GainMultiplier = 4,
		Color = Color3.fromRGB(239, 108, 61),
	},
	{
		Id = "Strongman",
		DisplayName = "Strongman Yard",
		Tagline = "Sand, salt and heavy stone.",
		RequiredPower = 50e3,
		GainMultiplier = 8,
		Color = Color3.fromRGB(190, 120, 70),
	},
	{
		Id = "Titan",
		DisplayName = "Titan Forge",
		Tagline = "The pit that ate a mountain.",
		RequiredPower = 500e3,
		GainMultiplier = 16,
		Color = Color3.fromRGB(255, 196, 61),
	},
	{
		Id = "Skydeck",
		DisplayName = "Sky Deck",
		Tagline = "Above the smog line.",
		RequiredPower = 5e6,
		GainMultiplier = 32,
		Color = Color3.fromRGB(120, 210, 255),
	},
	{
		Id = "Storm",
		DisplayName = "Storm Peak",
		Tagline = "Thin air and live cable.",
		RequiredPower = 50e6,
		GainMultiplier = 64,
		Color = Color3.fromRGB(150, 160, 255),
	},
	{
		Id = "Void",
		DisplayName = "Void Gym",
		Tagline = "No sun reaches this far out.",
		RequiredPower = 1.5e12,
		GainMultiplier = 400e3,
		Color = Color3.fromRGB(160, 110, 235),
	},
	{
		Id = "Solar",
		DisplayName = "Solar Forge",
		Tagline = "Lit from underneath.",
		RequiredPower = 30e12,
		GainMultiplier = 2.5e6,
		Color = Color3.fromRGB(255, 140, 60),
	},
	{
		Id = "Nebula",
		DisplayName = "Nebula Hall",
		Tagline = "Nothing below but colour.",
		RequiredPower = 600e12,
		GainMultiplier = 16e6,
		Color = Color3.fromRGB(255, 110, 190),
	},
	{
		Id = "Ascendant",
		DisplayName = "Ascendant Peak",
		Tagline = "The last place there is.",
		RequiredPower = 12e15,
		GainMultiplier = 100e6,
		Color = Color3.fromRGB(255, 245, 200),
	},
}

local ZoneConfig = {}

ZoneConfig.List = zones
ZoneConfig.ZONE_TAG = ZONE_TAG
ZoneConfig.SPAWN_TAG = SPAWN_TAG
ZoneConfig.ZONE_ATTRIBUTE = ZONE_ATTRIBUTE

local byId: { [string]: Zone } = {}
for _, zone in zones do
	if byId[zone.Id] ~= nil then
		error(`[ZoneConfig] Duplicate zone id "{zone.Id}"`)
	end
	byId[zone.Id] = zone
end

function ZoneConfig.Get(zoneId: string): Zone?
	return byId[zoneId]
end

--[[
	Resolves the zone a tagged part belongs to. Returns nil plus a reason when the part
	is misconfigured, so the server can log something a level designer can act on.
]]
function ZoneConfig.Resolve(part: Instance): (Zone?, string?)
	local zoneId = part:GetAttribute(ZONE_ATTRIBUTE)

	if zoneId == nil then
		return nil, `missing "{ZONE_ATTRIBUTE}" attribute`
	end
	if type(zoneId) ~= "string" then
		return nil, `"{ZONE_ATTRIBUTE}" must be a string, got {typeof(zoneId)}`
	end

	local zone = byId[zoneId]
	if zone == nil then
		return nil, `no zone defined with id "{zoneId}"`
	end

	return zone, nil
end

--[[
	The zone whose tagged volume contains a point, or nil out in the open.

	Used to tier a training station without anyone having to label it: a machine is
	worth whatever location volume contains it. When volumes overlap the richest wins,
	which makes an overlap generous rather than arbitrary.
]]
function ZoneConfig.AtPosition(position: Vector3): Zone?
	local best: Zone? = nil

	for _, volume in CollectionService:GetTagged(ZONE_TAG) do
		if not volume:IsA("BasePart") then
			continue
		end

		local local_ = volume.CFrame:PointToObjectSpace(position)
		local half = volume.Size / 2
		if math.abs(local_.X) > half.X or math.abs(local_.Y) > half.Y or math.abs(local_.Z) > half.Z then
			continue
		end

		local zone = ZoneConfig.Resolve(volume)
		if zone ~= nil and (best == nil or zone.GainMultiplier > best.GainMultiplier) then
			best = zone
		end
	end

	return best
end

return ZoneConfig
