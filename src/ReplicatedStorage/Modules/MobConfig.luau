--!strict
--[[
	MobConfig — the fourteen monsters, one field goblin and one boss per tier.

	Health and damage are written out rather than computed from the zone's
	RequiredPower. A formula would look tidier and be far worse to tune: these numbers
	are the difficulty curve of the whole combat game, and being able to grep one row
	and change one number beats deriving fourteen values from a coefficient nobody can
	picture. They are *chosen* against each zone's gate, which is a different thing
	from being *derived* from it.

	The shape of the curve, for anyone retuning it:

	  * Health tracks the tier's Power gate divided by roughly twenty, so a player who
	    has just earned entry to an area needs a handful of punches, not one and not
	    thirty. Damage from a punch is the attacker's Arms stat one-for-one.
	  * Mob damage is a small fraction of the health a player at that tier will have
	    (Formulas.MaxHealth is 100 + Chest * 10), so a goblin is a real threat to
	    someone who trained only Arms and an annoyance to someone who trained Chest.
	    That asymmetry is the point: Chest and Back are what make you survive here.
	  * A boss is roughly twelve field goblins of health and three of damage, which is
	    what makes it a thing you come back for on the timer rather than something you
	    clear on the way past.

	Rewards double with every tier, on both currencies. A goblin one tier up pays twice
	the Fight Tokens; a boss one tier up pays twice the Tokens. That matches the
	multiplier ladder and the physique ladder, which also double, so a fight is worth
	about the same fraction of your next purchase wherever you are on the map. Note the
	two are genuinely different currencies: goblins pay FightTokenReward, spent on
	physique transformations, and bosses pay TokenReward, spent on stat multipliers.
	Bosses are the only combat source of the multiplier currency.

	Both hostile sites are authored in scripts/build_gym.py as tagged, invisible
	markers, so the world says where monsters live and this table says what they are.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MuscleClassConfig = require(ReplicatedStorage.Modules.MuscleClassConfig)

export type MobKind = "Normal" | "Boss"

export type Mob = {
	Id: string,
	-- The ZoneConfig tier this monster belongs to. One Normal and one Boss per tier.
	ZoneId: string,
	Kind: MobKind,
	DisplayName: string,
	Health: number,
	-- Damage per swing, before the victim's Back rating blocks part of it.
	Damage: number,
	AttackCooldown: number,
	AttackRange: number,
	WalkSpeed: number,
	-- How close a player must come before it notices them.
	AggroRadius: number,
	-- How far from its home point it will chase before giving up and healing. This is
	-- what stops a Storm boss being walked back to the starter beach.
	LeashRadius: number,
	-- Normal only: how many live at once in the field, and the delay before one that
	-- died is replaced.
	Population: number?,
	RespawnSeconds: number?,
	-- Normal only: paid straight to the killer.
	FightTokenReward: number?,
	-- Boss only: the lump the timer is worth, and how long it waits to be fought
	-- before leaving so the next spawn cannot stack on top of it.
	TokenReward: number?,
	DespawnSeconds: number?,
	Color: Color3,
	-- Multiplies the base goblin build. Bosses are visibly bigger from across the arena.
	Scale: number,
	-- The highest physique-class bonus this monster's reward will accept. See TIER_CAP.
	RewardCap: number,
}

--[[
	How far a physique class may multiply this tier's boss reward.

	The class multiplier doubles nine times; rewards double seven times across the tiers.
	Multiplied together without a limit the cheapest content in the game becomes the best
	paid — a late class could sit on the 1,600-HP Garage boss and out-earn anyone
	fighting at their own level.

	So the bonus stops at what the tier is itself worth, the same doubling the rewards
	use. A Garage boss pays Garage rates to everyone forever; a Storm boss will pay up to
	sixty-four times. Killing things at your own level is what pays, which is the job the
	tier ladder already exists to do.
]]
local TIER_CAP: { [string]: number } = {
	Garage = 1,
	Iron = 2,
	Powerhouse = 4,
	Strongman = 8,
	Titan = 16,
	Skydeck = 32,
	Storm = 64,
}

local GOBLIN_GREEN = Color3.fromRGB(96, 138, 61)
local BOSS_RED = Color3.fromRGB(150, 46, 42)

local function goblin(
	zoneId: string,
	displayName: string,
	health: number,
	damage: number,
	fightTokens: number
): Mob
	return {
		Id = `{zoneId}Goblin`,
		ZoneId = zoneId,
		Kind = "Normal",
		DisplayName = displayName,
		Health = health,
		Damage = damage,
		AttackCooldown = 1.6,
		AttackRange = 9,
		WalkSpeed = 14,
		AggroRadius = 60,
		LeashRadius = 130,
		Population = 6,
		RespawnSeconds = 12,
		FightTokenReward = fightTokens,
		Color = GOBLIN_GREEN,
		Scale = 1,
		RewardCap = TIER_CAP[zoneId] or 1,
	}
end

local function boss(zoneId: string, displayName: string, health: number, damage: number, tokens: number): Mob
	return {
		Id = `{zoneId}Boss`,
		ZoneId = zoneId,
		Kind = "Boss",
		DisplayName = displayName,
		Health = health,
		Damage = damage,
		AttackCooldown = 2.2,
		AttackRange = 13,
		WalkSpeed = 12,
		AggroRadius = 90,
		LeashRadius = 110,
		TokenReward = tokens,
		-- Ten minutes of the thirty-minute cycle. Long enough to travel to, short
		-- enough that an unfought boss is gone well before the next one is due.
		DespawnSeconds = 600,
		Color = BOSS_RED,
		Scale = 2.1,
		RewardCap = TIER_CAP[zoneId] or 1,
	}
end

local mobs: { Mob } = {
	-- Garage (gate 0). Deliberately beatable by someone who has trained nothing:
	-- this is where a player learns that monsters hit back.
	goblin("Garage", "Runt Goblin", 120, 6, 1),
	boss("Garage", "Scrap Warden", 1600, 18, 10),

	-- Iron (gate 50K)
	goblin("Iron", "Park Goblin", 2500, 45, 2),
	boss("Iron", "Iron Warden", 30000, 130, 20),

	-- Powerhouse (gate 250K)
	goblin("Powerhouse", "Dock Goblin", 12500, 220, 4),
	boss("Powerhouse", "Tidebreaker", 150000, 640, 40),

	-- Strongman (gate 1M)
	goblin("Strongman", "Freight Goblin", 50000, 850, 8),
	boss("Strongman", "Yard Colossus", 600000, 2500, 80),

	-- Titan (gate 5M)
	goblin("Titan", "Plaza Goblin", 250000, 4200, 16),
	boss("Titan", "Titan of the Square", 3e6, 12500, 160),

	-- Skydeck (gate 25M)
	goblin("Skydeck", "Rooftop Goblin", 1.25e6, 21000, 32),
	boss("Skydeck", "Skydeck Sentinel", 15e6, 62000, 320),

	-- Storm (gate 250M). The flight-only tier, and the hardest thing in the game.
	goblin("Storm", "Storm Goblin", 12.5e6, 210000, 64),
	boss("Storm", "Stormcaller", 150e6, 620000, 640),
}

local MobConfig = {}

-- Tags written onto the invisible site markers by scripts/build_gym.py.
MobConfig.FIELD_TAG = "MobField"
MobConfig.ARENA_TAG = "BossArena"
-- Tag and attributes carried by a live monster model.
MobConfig.MOB_TAG = "Mob"
MobConfig.ID_ATTRIBUTE = "MobId"
MobConfig.ZONE_ATTRIBUTE = "ZoneId"
MobConfig.RADIUS_ATTRIBUTE = "Radius"

MobConfig.List = mobs

local byId: { [string]: Mob } = {}
local byZone: { [string]: { [MobKind]: Mob } } = {}
for _, mob in mobs do
	if byId[mob.Id] ~= nil then
		error(`[MobConfig] Duplicate mob id "{mob.Id}"`)
	end
	byId[mob.Id] = mob

	local zone = byZone[mob.ZoneId]
	if zone == nil then
		zone = {}
		byZone[mob.ZoneId] = zone
	end
	if zone[mob.Kind] ~= nil then
		error(`[MobConfig] Zone "{mob.ZoneId}" already has a {mob.Kind} mob`)
	end
	zone[mob.Kind] = mob
end

--[[
	What one kill is worth right now, as a multiplier on the reward written in the row.

	**Bosses only.** A goblin always pays its flat tier reward, however grand the killer
	is, because goblins pay Fight Tokens and Fight Tokens buy physique classes — so a
	class that multiplied them would be funding its own ladder. It is not a small effect:
	a class-2 player one-shots Powerhouse goblins, and at a scaled 16 a kill, six to a
	field on a twelve-second respawn, the entire 2,555 chain pays for itself in about
	five minutes. The tier cap cannot catch it either, since a player farms the very tier
	their class is capped at. Tying Fight Token income to *where* you fight rather than
	to what you already are is the only version of this that paces anything.

	Bosses pay Tokens, which buy stat multipliers, and multipliers do not make bosses
	easier to reach — so scaling those is just the reward growing with the character.
	The cap is still needed there, to stop a late class farming the starter boss.

	Both the server that pays the reward and the map card that promises it call this, so
	a card cannot quote one figure while the kill hands over another.
]]
function MobConfig.RewardMultiplier(mob: Mob, classLevel: number): number
	if mob.Kind ~= "Boss" then
		return 1
	end
	return math.min(MuscleClassConfig.Get(classLevel).TokenMultiplier, mob.RewardCap)
end

function MobConfig.Get(mobId: string): Mob?
	return byId[mobId]
end

--[[
	The monster of one kind belonging to one tier. Nil for a zone with no monsters,
	which is every dormant ZoneConfig row.
]]
function MobConfig.ForZone(zoneId: string, kind: MobKind): Mob?
	local zone = byZone[zoneId]
	return if zone ~= nil then zone[kind] else nil
end

--[[
	Reads a live monster model back to its definition, the same way EquipmentConfig
	resolves a station. Returns nil plus a reason so callers can warn usefully.
]]
function MobConfig.Resolve(model: Instance): (Mob?, string?)
	local mobId = model:GetAttribute(MobConfig.ID_ATTRIBUTE)
	if type(mobId) ~= "string" then
		return nil, `missing a string {MobConfig.ID_ATTRIBUTE} attribute`
	end
	local mob = byId[mobId]
	if mob == nil then
		return nil, `unknown mob id "{mobId}"`
	end
	return mob, nil
end

--[[
	Every authored site of one kind, as (marker, mob, radius). Skips markers whose zone
	has no monster defined rather than erroring, so adding a tier's geometry before its
	MobConfig row is a no-op instead of a crash.
]]
export type Site = {
	Marker: BasePart,
	Mob: Mob,
	Radius: number,
}

function MobConfig.Sites(kind: MobKind): { Site }
	local tag = if kind == "Boss" then MobConfig.ARENA_TAG else MobConfig.FIELD_TAG
	local sites: { Site } = {}

	for _, marker in CollectionService:GetTagged(tag) do
		if not marker:IsA("BasePart") then
			continue
		end
		local zoneId = marker:GetAttribute(MobConfig.ZONE_ATTRIBUTE)
		if type(zoneId) ~= "string" then
			continue
		end
		local mob = MobConfig.ForZone(zoneId, kind)
		if mob == nil then
			continue
		end
		local radius = marker:GetAttribute(MobConfig.RADIUS_ATTRIBUTE)
		table.insert(sites, {
			Marker = marker,
			Mob = mob,
			Radius = if type(radius) == "number" then radius else 60,
		})
	end

	return sites
end

return MobConfig
