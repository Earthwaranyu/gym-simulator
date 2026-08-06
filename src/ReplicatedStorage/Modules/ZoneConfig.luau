--!strict
--[[
	ZoneConfig — the gym tiers and what it takes to get into them.

	A zone is a tagged volume in the world; this table says what each one is called and
	how much power it demands. Adding a tier is an entry here plus a tagged part, with
	no code change.

	Zones do double duty: TokenService only accrues inside one, so the same volumes that
	gate progression also define where idling pays. That is deliberate — it keeps
	players in built areas where other players can find them.
]]

export type Zone = {
	Id: string,
	DisplayName: string,
	-- Total power needed to pass this zone's gate.
	RequiredPower: number,
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
-- Tag on a part that teleports the toucher into a zone.
local GATE_TAG = "ZoneGate"
-- Tag on the part a gate teleports you to.
local SPAWN_TAG = "ZoneSpawn"
-- Attribute naming which zone a tagged part belongs to.
local ZONE_ATTRIBUTE = "ZoneId"

local zones: { Zone } = {
	{
		Id = "Starter",
		DisplayName = "Starter Gym",
		RequiredPower = 0,
		Color = Color3.fromRGB(126, 211, 155),
	},
	{
		Id = "Iron",
		DisplayName = "Iron Hall",
		RequiredPower = 250000,
		Color = Color3.fromRGB(66, 165, 245),
	},
	{
		Id = "Titan",
		DisplayName = "Titan Arena",
		RequiredPower = 5e9,
		Color = Color3.fromRGB(255, 196, 61),
	},
}

local ZoneConfig = {}

ZoneConfig.List = zones
ZoneConfig.ZONE_TAG = ZONE_TAG
ZoneConfig.GATE_TAG = GATE_TAG
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

return ZoneConfig
